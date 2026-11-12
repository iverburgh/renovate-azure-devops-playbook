<#
.SYNOPSIS
    Sends the Renovate run report to a chat channel after every run.

.DESCRIPTION
    Runs as the last step of the Renovate pipeline, under all circumstances. Fetches the Renovate
    pull requests, reads the log file the Renovate step left behind, has New-RenovateTeamsReport.ps1
    turn both into a report and an Adaptive Card, and posts that to an incoming webhook.

    Exactly one message is always sent, including for zero pull requests and for a failed run. If
    the post itself fails, the step fails: a notification nobody receives is indistinguishable from
    a quiet week.

    The webhook is expected to be a Microsoft Teams workflow (Power Automate) with the trigger
    "When a Teams webhook request is received". See ../docs/notifications.md for how to set that up,
    and note the envelope requirement documented in ConvertTo-RenovateTeamsMessage.

.PARAMETER WebhookUrl
    The incoming webhook URL. Treat this as a secret: anyone holding it can post to your channel.
    Supply it through a secret pipeline variable, never in source control.

.PARAMETER LogPath
    Path to the Renovate log captured by the run step, used to detect blocked branches. Without it
    the 'possibly blocked' section reports 'not determined' rather than pretending it is empty.

.PARAMETER PrBranchPrefix
    Only pull requests from branches with this prefix are considered.

.PARAMETER LookbackDays
    How far back to look for abandoned pull requests, used to resolve blocking titles.

.PARAMETER AccessToken
    Personal access token, base64 encoded, for running outside a pipeline.

.NOTES
    Parameter names deliberately differ from those in New-RenovateWorkItems.ps1. That script is
    dot-sourced below for Get-RenovatePullRequest and New-AuthHeader, and dot-sourcing also brings
    its param defaults into scope - identically named parameters would be silently overwritten.
#>
param(
    [string]$WebhookUrl = $env:RENOVATE_NOTIFICATION_WEBHOOK_URL,
    [string]$LogPath = $env:RENOVATE_LOG_PATH,
    [string]$PrBranchPrefix = 'refs/heads/renovate/',
    [int]$LookbackDays = 14,
    [string]$AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'New-RenovateTeamsReport.ps1')
. (Join-Path $PSScriptRoot 'New-RenovateWorkItems.ps1')

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

function Get-RenovateRunStatus {
    <# In a separate notification job Agent.JobStatus describes that job; the Renovate outcome is then handed over explicitly. #>
    param([string]$Explicit, [string]$AgentJobStatus)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    return $AgentJobStatus
}

function Get-RenovateRunSucceeded {
    <# Maps Agent.JobStatus onto succeeded/failed; an unknown status counts as succeeded. #>
    param([string]$AgentJobStatus)
    return $AgentJobStatus -notin @('Failed', 'Canceled')
}

function ConvertTo-RenovateId {
    <# Parses a pipeline variable into a positive id; missing or unreadable means 0, so no link. #>
    param([object]$Value)
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return 0
}

function Resolve-RenovateRunStartTime {
    <#
    .SYNOPSIS
        Determines from which moment a pull request counts as 'new in this run'.

    .DESCRIPTION
        Prefers the moment the Renovate job recorded itself as ISO 8601. System.PipelineStartTime is only
        the fallback: without an offset it is read as UTC, and a culture-specific format is unreadable.
        Falls back to the current time when no source is readable. That is the safe direction: every pull
        request then lands under 'still open' instead of being wrongly announced as new.
    #>
    param(
        [object]$RenovateJobStartTime,
        [object]$PipelineStartTime,
        [datetime]$Fallback = (Get-Date).ToUniversalTime()
    )
    $parsed = ConvertTo-RenovateUtcDate $RenovateJobStartTime
    if ($null -ne $parsed) {
        Write-Host "Run start: $($parsed.ToString('o')) (source: renovate job)"
        return $parsed
    }
    $parsed = ConvertTo-RenovateUtcDate $PipelineStartTime
    if ($null -ne $parsed) {
        Write-Host "Run start: $($parsed.ToString('o')) (source: System.PipelineStartTime '$PipelineStartTime')"
        return $parsed
    }
    Write-Host "Run start unknown (renovate job: '$RenovateJobStartTime', System.PipelineStartTime: '$PipelineStartTime'); every pull request is listed as still open."
    return $Fallback.ToUniversalTime()
}

function Test-RenovateWebhookConfigured {
    <#
        An undefined pipeline variable arrives literally as '$(Name)', not as an empty string. Without
        this check the script would happily try to POST to that literal text.
    #>
    param([string]$WebhookUrl)
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return $false }
    if ($WebhookUrl -match '^\$\(.+\)$') { return $false }
    return $true
}

function Read-RenovateLogLine {
    <# Returns $null when there is no usable log content; the report then shows 'not determined'. #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "Renovate log file not found: $Path"
        return $null
    }

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if (-not (Test-RenovateLogAvailable -LogLine $lines)) {
        Write-Host "Renovate log file is empty: $Path"
        return $null
    }
    return $lines
}

# ---------------------------------------------------------------------------
# Sending and entry point
# ---------------------------------------------------------------------------

function Format-RenovateExceptionChain {
    <#
        Flattens the whole exception chain. The outer layer of a failed HTTPS call is often useless
        ("The SSL connection could not be established, see inner exception"); the actual reason only
        appears further in.
    #>
    param([System.Exception]$Exception)

    $parts = [System.Collections.Generic.List[string]]::new()
    $current = $Exception
    $depth = 0
    while ($null -ne $current -and $depth -lt 10) {
        $parts.Add("[$($current.GetType().Name)] $($current.Message)")
        $current = $current.InnerException
        $depth++
    }
    return ($parts -join ' -> ')
}

function Send-RenovateTeamsMessage {
    <#
        Posts the message to the webhook. Returns $false on failure; the caller then fails the step.

        This is deliberate. A notification that silently fails is worse than a red step, because
        this message is the only per-run overview once the Dependency Dashboard is off - and we
        learned that the hard way from a run that went green while nothing was ever delivered.

        Note that a 2xx response proves very little here: the Power Automate trigger accepts
        asynchronously and returns 202 even when the flow itself fails afterwards. The
        x-ms-workflow-run-id response header is what you need to find the actual run.
    #>
    param(
        [Parameter(Mandatory)][string]$WebhookUrl,
        [Parameter(Mandatory)][object]$Message
    )

    $json = $Message | ConvertTo-Json -Depth 20
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body $json | Out-Null
        Write-Host 'Notification sent.'
        return $true
    }
    catch {
        $detail = Format-RenovateExceptionChain -Exception $_.Exception
        Write-Host "##vso[task.logissue type=error]Notification failed: $detail"
        return $false
    }
}

function Invoke-TeamsNotification {
    if (-not (Test-RenovateWebhookConfigured -WebhookUrl $WebhookUrl)) {
        Write-Warning 'No webhook URL configured; skipping the notification.'
        return
    }

    $collectionUri = $env:SYSTEM_COLLECTIONURI
    if (-not $collectionUri) { $collectionUri = $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI }
    $project = $env:SYSTEM_TEAMPROJECT
    $repositoryId = $env:BUILD_REPOSITORY_ID
    $repositoryName = $env:BUILD_REPOSITORY_NAME

    foreach ($pair in @{ CollectionUri = $collectionUri; Project = $project; RepositoryId = $repositoryId; RepositoryName = $repositoryName }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($pair.Value)) { throw "Required pipeline variable is missing: $($pair.Key)" }
    }

    $headers = New-AuthHeader -Pat $AccessToken
    $prQuery = @{
        Headers       = $headers
        CollectionUri = $collectionUri
        Project       = $project
        RepositoryId  = $repositoryId
        BranchPrefix  = $PrBranchPrefix
    }

    $active = @(Get-RenovatePullRequest @prQuery -Status 'active' | Where-Object { $_.status -eq 'active' })
    $minClosed = (Get-Date).AddDays(-$LookbackDays)
    $abandoned = @(Get-RenovatePullRequest @prQuery -Status 'abandoned' -MinClosedTime $minClosed | Where-Object { $_.status -eq 'abandoned' })
    Write-Host "Renovate pull requests: active=$($active.Count), abandoned=$($abandoned.Count)"

    $report = New-RenovateRunReport `
        -ActivePullRequest $active `
        -AbandonedPullRequest $abandoned `
        -LogLine (Read-RenovateLogLine -Path $LogPath) `
        -RunStartTime (Resolve-RenovateRunStartTime -RenovateJobStartTime $env:RENOVATE_RUN_START_TIME -PipelineStartTime $env:SYSTEM_PIPELINESTARTTIME) `
        -RunSucceeded (Get-RenovateRunSucceeded -AgentJobStatus (Get-RenovateRunStatus -Explicit $env:RENOVATE_RUN_STATUS -AgentJobStatus $env:AGENT_JOBSTATUS)) `
        -RunItemId (ConvertTo-RenovateId -Value $env:RENOVATERUNITEMID) `
        -BuildId (ConvertTo-RenovateId -Value $env:BUILD_BUILDID) `
        -BuildNumber "$env:BUILD_BUILDNUMBER" `
        -CollectionUri $collectionUri `
        -Project $project `
        -Repository $repositoryName

    Write-Host "Report: new=$(@($report.New).Count), open=$(@($report.Open).Count), blocked=$(@($report.Blocking).Count), blocking determined=$($report.BlockingDetermined)"

    $message = ConvertTo-RenovateTeamsMessage -Card (ConvertTo-RenovateAdaptiveCard -Report $report)
    if (-not (Send-RenovateTeamsMessage -WebhookUrl $WebhookUrl -Message $message)) {
        throw 'Sending the run notification failed; see the error above.'
    }
}

# Dot-sourcing (both the Pester tests and the PowerShell@2 task) only loads the functions.
# The caller invokes Invoke-TeamsNotification explicitly.
