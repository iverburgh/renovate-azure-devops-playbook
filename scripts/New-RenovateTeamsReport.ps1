<#
.SYNOPSIS
    Builds the report and Adaptive Card payload for a Renovate run notification.

.DESCRIPTION
    Turns a Renovate log file plus the repository's Renovate pull requests into the report that is
    posted to a chat channel after every run, and converts that report into an Adaptive Card.

    The report has three sections:
      - New in this run : active renovate/ pull requests created during this run
      - Still open      : the remaining active renovate/ pull requests
      - Possibly blocked: branches Renovate skipped because a closed pull request with the same
                          title already exists, which prevents it from creating a new one

    Every function here is pure: no network calls, no pipeline context. Reading the log, fetching
    the pull requests and sending the payload are the caller's job - see
    Send-RenovateTeamsNotification.ps1. Tests live in New-RenovateTeamsReport.Tests.ps1.

    Design note: a message is always produced, including for a run with zero pull requests and for
    a failed run. Silence is ambiguous - it looks identical to a broken notification step.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pinned against real Renovate log lines (Renovate 44.x):
#   DEBUG: Closed PR #1234 already exists. Skipping branch. (repository=..., baseBranch=main, branch=renovate/foo)
$script:SkippedBranchPattern = 'Closed PR #(?<prId>\d+) already exists\.\s*Skipping branch\.'

# The negative lookbehind matters: PowerShell -match is case-insensitive, so a naive 'branch='
# pattern reads the value of 'baseBranch=' instead.
$script:BranchPattern = '(?<![A-Za-z])branch=(?<branch>[^,)\s]+)'
$script:BaseBranchPattern = 'baseBranch=(?<baseBranch>[^,)\s]+)'

# Optional footer linking to your own runbook. Leave HelpUrl empty to omit the footer entirely.
$script:HelpTitle = 'Need help handling these pull requests?'
$script:HelpLinkLabel = 'Dependency update runbook'
$script:HelpUrl = ''

# ---------------------------------------------------------------------------
# Pure helpers - no network, no pipeline context
# ---------------------------------------------------------------------------

function Get-OptionalProperty {
    <# Reads a property without failing when it is absent; required under Set-StrictMode. #>
    param(
        [object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [object]$Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function ConvertTo-RenovateUtcDate {
    <# Converts an Azure DevOps date (ISO string or datetime) to UTC; $null when unreadable. #>
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }

    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-RenovatePrUrl {
    param(
        [Parameter(Mandatory)][string]$CollectionUri,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$PullRequestId
    )
    return "$($CollectionUri.TrimEnd('/'))/$Project/_git/$Repository/pullrequest/$PullRequestId"
}

function Get-RenovateWorkItemUrl {
    param(
        [Parameter(Mandatory)][string]$CollectionUri,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][int]$WorkItemId
    )
    return "$($CollectionUri.TrimEnd('/'))/$Project/_workitems/edit/$WorkItemId"
}

function Get-RenovateBuildUrl {
    param(
        [Parameter(Mandatory)][string]$CollectionUri,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][int]$BuildId
    )
    return "$($CollectionUri.TrimEnd('/'))/$Project/_build/results?buildId=$BuildId"
}

function Get-RenovateSkippedBranch {
    <#
    .SYNOPSIS
        Extracts from the Renovate log which branches were skipped because a closed pull request
        with the same title already exists.

    .DESCRIPTION
        This has to come from the log, not from pull request status. Renovate's recreateClosed
        behaviour is not uniform - grouped branches sometimes run with "recreating closed PRs is
        disabled" and sometimes not - so filtering on group names would silently hide real
        blockages. The log line always carries the pull request number, which makes it linkable
        even when the pull request itself falls outside the lookback window.
    #>
    param([string[]]$LogLine = @())

    $seen = @{}
    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $LogLine) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $skip = [regex]::Match($line, $script:SkippedBranchPattern)
        if (-not $skip.Success) { continue }

        $pullRequestId = [int]$skip.Groups['prId'].Value

        $branchMatch = [regex]::Match($line, $script:BranchPattern)
        $branch = if ($branchMatch.Success) { $branchMatch.Groups['branch'].Value } else { '' }

        $baseMatch = [regex]::Match($line, $script:BaseBranchPattern)
        $baseBranch = if ($baseMatch.Success) { $baseMatch.Groups['baseBranch'].Value } else { '' }

        # Renovate logs once per base branch; the same blockage should appear only once.
        $key = "$pullRequestId|$branch"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $result.Add([pscustomobject]@{
                PullRequestId = $pullRequestId
                Branch        = $branch
                BaseBranch    = $baseBranch
            })
    }

    return @($result)
}

function Split-RenovatePullRequest {
    <#
    .SYNOPSIS
        Splits active Renovate pull requests into 'new in this run' and 'still open'.

    .DESCRIPTION
        A pull request counts as new when it was created at or after the run start time. One
        without a readable creationDate lands in 'still open': reporting an existing pull request
        as new is more misleading than the other way round.
    #>
    param(
        [object[]]$PullRequest = @(),
        [Parameter(Mandatory)][datetime]$RunStartTime
    )

    $threshold = $RunStartTime.ToUniversalTime()
    $new = [System.Collections.Generic.List[object]]::new()
    $open = [System.Collections.Generic.List[object]]::new()

    foreach ($pr in $PullRequest) {
        if ($null -eq $pr) { continue }
        $created = ConvertTo-RenovateUtcDate (Get-OptionalProperty -InputObject $pr -Name 'creationDate')
        if ($null -ne $created -and $created -ge $threshold) { $new.Add($pr) } else { $open.Add($pr) }
    }

    return [pscustomobject]@{
        New  = @($new)
        Open = @($open)
    }
}

function Resolve-RenovateBlockingPr {
    <#
    .SYNOPSIS
        Enriches the skipped branches from the log with the title of the blocking pull request.

    .DESCRIPTION
        When the pull request is not found in the supplied list - for example because it closed
        before the lookback window - the branch name is shown instead. The link survives either
        way, because the pull request number comes from the log line itself.
    #>
    param(
        [object[]]$SkippedBranch = @(),
        [object[]]$AbandonedPullRequest = @(),
        [Parameter(Mandatory)][string]$CollectionUri,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Repository
    )

    $byId = @{}
    foreach ($pr in $AbandonedPullRequest) {
        $id = Get-OptionalProperty -InputObject $pr -Name 'pullRequestId'
        if ($null -ne $id) { $byId[[int]$id] = $pr }
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($skipped in $SkippedBranch) {
        if ($null -eq $skipped) { continue }
        $id = [int](Get-OptionalProperty -InputObject $skipped -Name 'PullRequestId' -Default 0)
        $branch = [string](Get-OptionalProperty -InputObject $skipped -Name 'Branch' -Default '')

        if ($byId.ContainsKey($id)) {
            $title = [string](Get-OptionalProperty -InputObject $byId[$id] -Name 'title' -Default $branch)
            $result.Add([pscustomobject]@{
                    PullRequestId = $id
                    Branch        = $branch
                    Title         = $title
                    Label         = "#$id $title"
                    Url           = Get-RenovatePrUrl -CollectionUri $CollectionUri -Project $Project -Repository $Repository -PullRequestId $id
                })
        }
        else {
            $url = $null
            if ($id -gt 0) { $url = Get-RenovatePrUrl -CollectionUri $CollectionUri -Project $Project -Repository $Repository -PullRequestId $id }
            $result.Add([pscustomobject]@{
                    PullRequestId = $id
                    Branch        = $branch
                    Title         = $null
                    Label         = $branch
                    Url           = $url
                })
        }
    }

    return @($result)
}

function ConvertTo-RenovateReportItem {
    <# Maps an Azure DevOps pull request object onto the shape the report renders. #>
    param(
        [object[]]$PullRequest = @(),
        [Parameter(Mandatory)][string]$CollectionUri,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Repository
    )

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($pr in $PullRequest) {
        if ($null -eq $pr) { continue }
        $id = Get-OptionalProperty -InputObject $pr -Name 'pullRequestId'
        if ($null -eq $id) { continue }
        $id = [int]$id
        $title = [string](Get-OptionalProperty -InputObject $pr -Name 'title' -Default "PR $id")

        $result.Add([pscustomobject]@{
                PullRequestId = $id
                Title         = $title
                Label         = "#$id $title"
                Url           = Get-RenovatePrUrl -CollectionUri $CollectionUri -Project $Project -Repository $Repository -PullRequestId $id
            })
    }

    return @($result)
}

function Test-RenovateLogAvailable {
    <# Without usable log content there is no way to tell what was skipped. #>
    param([string[]]$LogLine)

    if ($null -eq $LogLine) { return $false }
    foreach ($line in $LogLine) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { return $true }
    }
    return $false
}

function New-RenovateRunReport {
    <#
    .SYNOPSIS
        Assembles the full run report from pull request data and the Renovate log.

    .DESCRIPTION
        A report is always produced, including for zero pull requests and for a failed run. When
        log content is missing, BlockingDetermined is $false: 'possibly blocked' is then unknown,
        which is deliberately distinct from empty.
    #>
    param(
        [object[]]$ActivePullRequest = @(),
        [object[]]$AbandonedPullRequest = @(),
        [string[]]$LogLine,
        [Parameter(Mandatory)][datetime]$RunStartTime,
        [bool]$RunSucceeded = $true,
        [int]$RunItemId = 0,
        [int]$BuildId = 0,
        [string]$BuildNumber = '',
        [Parameter(Mandatory)][string]$CollectionUri,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Repository
    )

    $urlContext = @{ CollectionUri = $CollectionUri; Project = $Project; Repository = $Repository }

    $split = Split-RenovatePullRequest -PullRequest $ActivePullRequest -RunStartTime $RunStartTime

    $blockingDetermined = Test-RenovateLogAvailable -LogLine $LogLine
    $blocking = @()
    if ($blockingDetermined) {
        $skipped = Get-RenovateSkippedBranch -LogLine $LogLine
        $blocking = Resolve-RenovateBlockingPr -SkippedBranch $skipped -AbandonedPullRequest $AbandonedPullRequest @urlContext
    }

    $buildUrl = $null
    if ($BuildId -gt 0) { $buildUrl = Get-RenovateBuildUrl -CollectionUri $CollectionUri -Project $Project -BuildId $BuildId }

    $runItemUrl = $null
    if ($RunItemId -gt 0) { $runItemUrl = Get-RenovateWorkItemUrl -CollectionUri $CollectionUri -Project $Project -WorkItemId $RunItemId }

    return [pscustomobject]@{
        RunSucceeded       = $RunSucceeded
        BuildNumber        = $BuildNumber
        BuildUrl           = $buildUrl
        RunItemId          = $RunItemId
        RunItemUrl         = $runItemUrl
        New                = ConvertTo-RenovateReportItem -PullRequest $split.New @urlContext
        Open               = ConvertTo-RenovateReportItem -PullRequest $split.Open @urlContext
        Blocking           = @($blocking)
        BlockingDetermined = $blockingDetermined
    }
}

function Format-RenovateLink {
    <# Markdown link for an Adaptive Card TextBlock; without a url only the label remains. #>
    param(
        [string]$Label,
        [string]$Url
    )
    $safeLabel = ([string]$Label) -replace '\[', '(' -replace '\]', ')'
    if ([string]::IsNullOrWhiteSpace($Url)) { return $safeLabel }
    return "[$safeLabel]($Url)"
}

function Format-RenovateSection {
    <# Lines for one report section; empty and unknown deliberately read differently. #>
    param(
        [object[]]$Item = @(),
        [switch]$Undetermined,
        [string]$EmptyText = 'none',
        [string]$UnknownText = 'not determined'
    )

    if ($Undetermined) { return @($UnknownText) }
    if ($null -eq $Item -or $Item.Count -eq 0) { return @($EmptyText) }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Item) {
        $label = [string](Get-OptionalProperty -InputObject $entry -Name 'Label' -Default '')
        $url = [string](Get-OptionalProperty -InputObject $entry -Name 'Url' -Default '')
        $lines.Add('- ' + (Format-RenovateLink -Label $label -Url $url))
    }
    return @($lines)
}

function ConvertTo-RenovateAdaptiveCard {
    <#
    .SYNOPSIS
        Converts the run report into an Adaptive Card. The caller serialises it with ConvertTo-Json.

    .PARAMETER HelpUrl
        Optional link to your own runbook, shown as a footer. Empty omits the footer entirely.
    #>
    param(
        [Parameter(Mandatory)][object]$Report,
        [string]$HelpTitle = $script:HelpTitle,
        [string]$HelpLinkLabel = $script:HelpLinkLabel,
        [string]$HelpUrl = $script:HelpUrl
    )

    $succeeded = [bool](Get-OptionalProperty -InputObject $Report -Name 'RunSucceeded' -Default $true)
    $status = if ($succeeded) { 'succeeded' } else { 'failed' }
    $buildNumber = [string](Get-OptionalProperty -InputObject $Report -Name 'BuildNumber' -Default '')
    $buildUrl = [string](Get-OptionalProperty -InputObject $Report -Name 'BuildUrl' -Default '')
    $runItemId = [int](Get-OptionalProperty -InputObject $Report -Name 'RunItemId' -Default 0)
    $runItemUrl = [string](Get-OptionalProperty -InputObject $Report -Name 'RunItemUrl' -Default '')

    $subtitleParts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($buildNumber)) {
        $subtitleParts.Add((Format-RenovateLink -Label "Run $buildNumber" -Url $buildUrl))
    }
    if ($runItemId -gt 0) {
        $subtitleParts.Add((Format-RenovateLink -Label "Run item #$runItemId" -Url $runItemUrl))
    }

    $body = [System.Collections.Generic.List[object]]::new()
    $body.Add(@{ type = 'TextBlock'; text = "Renovate dependency updates - run $status"; weight = 'Bolder'; size = 'Medium'; wrap = $true })
    if ($subtitleParts.Count -gt 0) {
        $body.Add(@{ type = 'TextBlock'; text = ($subtitleParts -join '  |  '); isSubtle = $true; wrap = $true })
    }

    $sections = @(
        @{ Title = 'New in this run'; Items = @(Get-OptionalProperty -InputObject $Report -Name 'New' -Default @()); Undetermined = $false }
        @{ Title = 'Still open'; Items = @(Get-OptionalProperty -InputObject $Report -Name 'Open' -Default @()); Undetermined = $false }
        @{ Title = 'Possibly blocked'; Items = @(Get-OptionalProperty -InputObject $Report -Name 'Blocking' -Default @()); Undetermined = -not [bool](Get-OptionalProperty -InputObject $Report -Name 'BlockingDetermined' -Default $false) }
    )

    foreach ($section in $sections) {
        $body.Add(@{ type = 'TextBlock'; text = $section.Title; weight = 'Bolder'; separator = $true; wrap = $true })
        $lines = Format-RenovateSection -Item $section.Items -Undetermined:$section.Undetermined
        $body.Add(@{ type = 'TextBlock'; text = ($lines -join "`n`n"); wrap = $true })
    }

    if (-not [string]::IsNullOrWhiteSpace($HelpUrl)) {
        $body.Add(@{ type = 'TextBlock'; text = $HelpTitle; weight = 'Bolder'; separator = $true; wrap = $true })
        $body.Add(@{ type = 'TextBlock'; text = (Format-RenovateLink -Label $HelpLinkLabel -Url $HelpUrl); wrap = $true })
    }

    return @{
        type      = 'AdaptiveCard'
        version   = '1.4'
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        body      = @($body)
    }
}

function ConvertTo-RenovateTeamsMessage {
    <#
    .SYNOPSIS
        Wraps the Adaptive Card in the envelope the Teams webhook trigger expects.

    .DESCRIPTION
        The Power Automate trigger "When a Teams webhook request is received" iterates over
        body.attachments and posts @item()?['content'] per attachment. A bare Adaptive Card makes
        the flow fail on a null array, and the HTTP call still returns 202 - so the failure is
        invisible from the caller's side. Always send exactly one attachment.
    #>
    param([Parameter(Mandatory)][object]$Card)

    return @{
        type        = 'message'
        attachments = @(
            @{
                contentType = 'application/vnd.microsoft.card.adaptive'
                contentUrl  = $null
                content     = $Card
            }
        )
    }
}
