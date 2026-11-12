<#
.SYNOPSIS
    Creates and maintains Azure DevOps work items for Renovate pull requests.

.DESCRIPTION
    Runs after Renovate. For every pipeline run it creates one "run" work item in the team's current
    iteration, links each open Renovate pull request to its own child work item, and moves child
    items of abandoned pull requests to a removed state.

    The Done transition on merge is normally handled by Azure DevOps itself ("complete linked work
    items"). This script also does it as a safety net, because that option is easy to leave off and
    the work items then stay open forever.

    Why bother: Renovate opens pull requests outside your normal planning flow, so dependency work
    is invisible on the board. One work item per run plus one per pull request makes the effort
    visible and reviewable without anyone having to remember to create them.

    The pure helper functions (parsing, idempotency, payload construction) are tested separately
    from the REST calls - see New-RenovateWorkItems.Tests.ps1.

.PARAMETER ParentWorkItemId
    Optional parent for the run work item, for example an epic or feature that collects all
    dependency work. 0 creates the run item without a parent.

.PARAMETER RunWorkItemType
    Work item type for the per-run item. Depends on your process template: "Product Backlog Item"
    on Scrum, "User Story" on Agile, "Issue" on Basic.

.PARAMETER RunWorkItemState
    State to create the run item in. "Committed" on Scrum, "Active" on Agile. Azure DevOps accepts
    a non-default state directly on creation; no second call is needed.

.PARAMETER PrWorkItemType
    Work item type for the per-pull-request child items.

.PARAMETER Team
    Team whose current iteration is used. Defaults to the project name, which is the default team
    in a new Azure DevOps project.

.PARAMETER AreaPath
    Area path for created work items. Empty uses the project default.

.PARAMETER BranchPrefix
    Only pull requests from branches with this prefix are considered. Matches Renovate's
    branchPrefix, which defaults to "renovate/".

.PARAMETER ClosedPrLookbackDays
    How far back to look for closed pull requests when syncing states. Without a bound this query
    grows with the repository history.

.PARAMETER Pat
    Personal access token, base64 encoded, for running outside a pipeline. Inside a pipeline the
    script uses SYSTEM_ACCESSTOKEN instead.

.EXAMPLE
    . ./New-RenovateWorkItems.ps1; Invoke-Main

    How the pipeline calls it. The PowerShell@2 task dot-sources the script, so the entry point
    must be invoked explicitly.

.EXAMPLE
    . ./New-RenovateWorkItems.ps1; Invoke-Main -WhatIf

    Shows what would be created without writing anything.
#>
param(
    [int]$ParentWorkItemId = 0,
    [string]$RunWorkItemType = 'Product Backlog Item',
    [string]$RunWorkItemState = 'Committed',
    [string]$PrWorkItemType = 'Task',
    [string]$Team = '',
    [string]$AreaPath = '',
    [string]$BranchPrefix = 'refs/heads/renovate/',
    [int]$ClosedPrLookbackDays = 14,
    [string]$RunItemDescription = 'This work item collects the Renovate dependency update pull requests of a single pipeline run. Each child item is linked to one pull request. Review the linked pull request per child item and merge it if you agree (the child item then moves to Done automatically), or abandon the pull request to reject it (the child item is set to Removed on the next run). Close this item once every child has been handled.',
    [string]$Pat,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ApiVersion = '7.1'

# ---------------------------------------------------------------------------
# Pure helpers - no REST, unit tested in *.Tests.ps1
# ---------------------------------------------------------------------------

function Get-RenovatePrLevel {
    <# Derives major/minor/patch from the pull request title or source branch; 'update' otherwise. #>
    param([string]$Title, [string]$SourceBranch)
    foreach ($text in @($Title, $SourceBranch)) {
        if ($text -and $text -match '(?i)\b(major|minor|patch)\b') { return $Matches[1].ToLower() }
    }
    return 'update'
}

function Format-RenovateTaskTitle {
    param([int]$PullRequestId, [string]$PrTitle)
    return "Renovate PR #${PullRequestId}: $PrTitle"
}

function Select-PrsNeedingTask {
    <# Idempotency: returns pull requests whose id is not already in $PrIdsWithTask. #>
    param(
        [object[]]$PullRequests = @(),
        [int[]]$PrIdsWithTask = @()
    )
    return @($PullRequests | Where-Object { $PrIdsWithTask -notcontains $_.pullRequestId })
}

function Get-TaskStateForPrStatus {
    <# completed -> Done (safety net), abandoned -> Removed, anything else -> $null (leave alone). #>
    param([string]$PrStatus)
    switch ($PrStatus) {
        'completed' { return 'Done' }
        'abandoned' { return 'Removed' }
        default { return $null }
    }
}

function Test-ShouldSetState {
    <# Only mutate when the item is not already in the target state or in a terminal state. #>
    param([string]$CurrentState, [string]$TargetState)
    if ($CurrentState -eq $TargetState) { return $false }
    if (@('Done', 'Removed', 'Closed') -contains $CurrentState) { return $false }
    return $true
}

function ConvertTo-PrArtifactUri {
    <# The vstfs artifact URI that links a work item to a pull request. #>
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][int]$PullRequestId
    )
    $encoded = [uri]::EscapeDataString("$ProjectId/$RepositoryId/$PullRequestId")
    return "vstfs:///Git/PullRequestId/$encoded"
}

function New-TaskPatchDocument {
    <# JSON patch document for a child work item, including parent link and pull request link. #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$AreaPath,
        [Parameter(Mandatory)][string]$IterationPath,
        [Parameter(Mandatory)][string]$ParentUrl,
        [Parameter(Mandatory)][string]$PrArtifactUri
    )
    $doc = @(
        @{ op = 'add'; path = '/fields/System.Title'; value = $Title }
    )
    if ($AreaPath) {
        $doc += @{ op = 'add'; path = '/fields/System.AreaPath'; value = $AreaPath }
    }
    $doc += @{ op = 'add'; path = '/fields/System.IterationPath'; value = $IterationPath }
    $doc += @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = $ParentUrl } }
    $doc += @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'ArtifactLink'; url = $PrArtifactUri; attributes = @{ name = 'Pull Request' } } }
    return $doc
}

# ---------------------------------------------------------------------------
# REST helpers - thin; orchestration lives in Invoke-Main
# ---------------------------------------------------------------------------

function New-AuthHeader {
    param([string]$Pat)
    if ($Pat) { return @{ Authorization = "Basic $Pat" } }
    if ([string]::IsNullOrEmpty($env:SYSTEM_ACCESSTOKEN)) {
        throw 'No -Pat supplied and SYSTEM_ACCESSTOKEN is not set.'
    }
    return @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" }
}

function Get-CurrentIterationPath {
    param([hashtable]$Headers, [string]$CollectionUri, [string]$Project, [string]$Team)
    $uri = "${CollectionUri}${Project}/${Team}/_apis/work/teamsettings/iterations?`$timeframe=current&api-version=$script:ApiVersion"
    $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get
    if (-not $resp.value -or $resp.value.Count -eq 0) { throw "No current iteration found for team '$Team'." }
    return $resp.value[0].path
}

function New-WorkItem {
    param(
        [hashtable]$Headers, [string]$CollectionUri, [string]$Project,
        [string]$Type, [object[]]$PatchDocument
    )
    $uri = "${CollectionUri}${Project}/_apis/wit/workitems/`$${Type}?api-version=$script:ApiVersion"
    $body = ConvertTo-Json $PatchDocument -Depth 10
    $h = $Headers.Clone(); $h['Content-Type'] = 'application/json-patch+json'
    return Invoke-RestMethod -Uri $uri -Headers $h -Method Post -Body $body
}

function Get-RenovatePullRequest {
    <#
        Fetches Renovate pull requests for one status, paginated so nothing is silently truncated.
        For closed statuses, -MinClosedTime bounds the query to recently closed pull requests so the
        call does not grow with the repository history.
    #>
    param(
        [hashtable]$Headers, [string]$CollectionUri, [string]$Project, [string]$RepositoryId,
        [string]$BranchPrefix, [string]$Status = 'active', [datetime]$MinClosedTime, [int]$PageSize = 100
    )
    $base = "${CollectionUri}${Project}/_apis/git/repositories/${RepositoryId}/pullrequests?searchCriteria.status=$Status"
    if ($PSBoundParameters.ContainsKey('MinClosedTime')) {
        $base += '&searchCriteria.queryTimeRangeType=Closed&searchCriteria.minTime=' + [uri]::EscapeDataString($MinClosedTime.ToString('o'))
    }
    $base += "&api-version=$script:ApiVersion"

    $all = @()
    $skip = 0
    do {
        $uri = "${base}&`$top=$PageSize&`$skip=$skip"
        $page = @((Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get).value)
        $all += $page
        $skip += $PageSize
    } while ($page.Count -eq $PageSize)

    return @($all | Where-Object { $_.sourceRefName -and $_.sourceRefName.StartsWith($BranchPrefix) })
}

function Get-PrLinkedWorkItemId {
    param([hashtable]$Headers, [string]$CollectionUri, [string]$Project, [string]$RepositoryId, [int]$PullRequestId)
    $uri = "${CollectionUri}${Project}/_apis/git/repositories/${RepositoryId}/pullRequests/${PullRequestId}/workitems?api-version=$script:ApiVersion"
    $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get
    return @($resp.value | ForEach-Object { [int]$_.id })
}

function Get-WorkItemState {
    param([hashtable]$Headers, [string]$CollectionUri, [string]$Project, [int]$Id)
    $uri = "${CollectionUri}${Project}/_apis/wit/workitems/${Id}?`$fields=System.State&api-version=$script:ApiVersion"
    $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get
    return $resp.fields.'System.State'
}

function Set-WorkItemState {
    param([hashtable]$Headers, [string]$CollectionUri, [string]$Project, [int]$Id, [string]$State)
    $uri = "${CollectionUri}${Project}/_apis/wit/workitems/${Id}?api-version=$script:ApiVersion"
    $body = ConvertTo-Json @(@{ op = 'add'; path = '/fields/System.State'; value = $State }) -Depth 5
    $h = $Headers.Clone(); $h['Content-Type'] = 'application/json-patch+json'
    return Invoke-RestMethod -Uri $uri -Headers $h -Method Patch -Body $body
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Invoke-Main {
    # -WhatIf works both on the dot-sourced script and on this call. Without this parameter a
    # documented `Invoke-Main -WhatIf` would silently be ignored and write for real.
    param([Alias('WhatIf')][switch]$DryRun)
    $WhatIf = $DryRun.IsPresent -or [bool](Get-Variable -Name WhatIf -ValueOnly -ErrorAction SilentlyContinue)

    $headers = New-AuthHeader -Pat $Pat

    $collectionUri = $env:SYSTEM_COLLECTIONURI
    if (-not $collectionUri) { $collectionUri = $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI }
    $project = $env:SYSTEM_TEAMPROJECT
    $projectId = $env:SYSTEM_TEAMPROJECTID
    $repositoryId = $env:BUILD_REPOSITORY_ID

    foreach ($pair in @{ CollectionUri = $collectionUri; Project = $project; ProjectId = $projectId; RepositoryId = $repositoryId }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($pair.Value)) { throw "Required pipeline variable is missing: $($pair.Key)" }
    }

    $teamName = if ($Team) { $Team } else { $project }
    $iterationPath = Get-CurrentIterationPath -Headers $headers -CollectionUri $collectionUri -Project $project -Team $teamName
    Write-Host "Current iteration: $iterationPath"

    # 1. One run work item per pipeline run, also when there are no pull requests at all.
    $runPatch = @(
        @{ op = 'add'; path = '/fields/System.Title'; value = "Renovate dependency updates - $(Get-Date -Format 'yyyy-MM-dd')" }
        @{ op = 'add'; path = '/fields/System.State'; value = $RunWorkItemState }
        @{ op = 'add'; path = '/fields/System.Description'; value = $RunItemDescription }
        @{ op = 'add'; path = '/fields/System.IterationPath'; value = $iterationPath }
    )
    if ($AreaPath) {
        $runPatch += @{ op = 'add'; path = '/fields/System.AreaPath'; value = $AreaPath }
    }
    if ($ParentWorkItemId -gt 0) {
        $parentUrl = "${collectionUri}_apis/wit/workItems/${ParentWorkItemId}"
        $runPatch += @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = $parentUrl } }
    }

    if ($WhatIf) {
        Write-Host "[WhatIf] Would create a $RunWorkItemType in $iterationPath"
        $runItemId = -1
    }
    else {
        $runItem = New-WorkItem -Headers $headers -CollectionUri $collectionUri -Project $project -Type $RunWorkItemType -PatchDocument $runPatch
        $runItemId = $runItem.id
        Write-Host "Run work item created: #$runItemId"
    }
    # Published so a later step, such as a chat notification, can link back to it. As an output
    # variable, so it also crosses into another job; that requires `name: governance` on the step.
    # Only a real id: a WhatIf run or a failed creation must not hand over a link to nothing.
    if ($runItemId -gt 0) { Write-Host "##vso[task.setvariable variable=RenovateRunItemId;isOutput=true]$runItemId" }
    $runItemUrl = "${collectionUri}_apis/wit/workItems/${runItemId}"

    # 2. Active pull requests drive item creation; recently closed ones drive state cleanup.
    $minClosed = (Get-Date).AddDays(-$ClosedPrLookbackDays)
    $prArgs = @{ Headers = $headers; CollectionUri = $collectionUri; Project = $project; RepositoryId = $repositoryId; BranchPrefix = $BranchPrefix }
    $active = @(Get-RenovatePullRequest @prArgs -Status 'active' | Where-Object { $_.status -eq 'active' })
    $completed = @(Get-RenovatePullRequest @prArgs -Status 'completed' -MinClosedTime $minClosed | Where-Object { $_.status -eq 'completed' })
    $abandoned = @(Get-RenovatePullRequest @prArgs -Status 'abandoned' -MinClosedTime $minClosed | Where-Object { $_.status -eq 'abandoned' })
    Write-Host "Renovate pull requests: active=$($active.Count), completed=$($completed.Count), abandoned=$($abandoned.Count)"

    # 3. Idempotency: which active pull requests have no linked work item yet?
    $prIdsWithTask = @()
    foreach ($pr in $active) {
        if (@(Get-PrLinkedWorkItemId -Headers $headers -CollectionUri $collectionUri -Project $project -RepositoryId $repositoryId -PullRequestId $pr.pullRequestId).Count -gt 0) {
            $prIdsWithTask += [int]$pr.pullRequestId
        }
    }
    $needTask = @(Select-PrsNeedingTask -PullRequests $active -PrIdsWithTask $prIdsWithTask)

    $createdTaskCount = 0
    foreach ($pr in $needTask) {
        $title = Format-RenovateTaskTitle -PullRequestId $pr.pullRequestId -PrTitle $pr.title
        $artifact = ConvertTo-PrArtifactUri -ProjectId $projectId -RepositoryId $repositoryId -PullRequestId $pr.pullRequestId
        $patch = New-TaskPatchDocument -Title $title -AreaPath $AreaPath -IterationPath $iterationPath -ParentUrl $runItemUrl -PrArtifactUri $artifact
        if ($WhatIf) {
            Write-Host "[WhatIf] Would create and link an item for PR #$($pr.pullRequestId): $($pr.title)"
        }
        else {
            $task = New-WorkItem -Headers $headers -CollectionUri $collectionUri -Project $project -Type $PrWorkItemType -PatchDocument $patch
            Write-Host "Item #$($task.id) created and linked to PR #$($pr.pullRequestId)"
        }
        $createdTaskCount++
    }

    # A run with no new pull requests still gets a child item, so an empty run is visibly empty
    # rather than looking like the step never ran.
    if ($createdTaskCount -eq 0) {
        $placeholderPatch = @(
            @{ op = 'add'; path = '/fields/System.Title'; value = 'No pull requests created in this run' }
            @{ op = 'add'; path = '/fields/System.IterationPath'; value = $iterationPath }
            @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = $runItemUrl } }
        )
        if ($AreaPath) {
            $placeholderPatch += @{ op = 'add'; path = '/fields/System.AreaPath'; value = $AreaPath }
        }
        if ($WhatIf) {
            Write-Host '[WhatIf] Would create a placeholder item: no pull requests in this run'
        }
        else {
            $ph = New-WorkItem -Headers $headers -CollectionUri $collectionUri -Project $project -Type $PrWorkItemType -PatchDocument $placeholderPatch
            Write-Host "Placeholder item #$($ph.id) created: no pull requests in this run"
        }
    }

    # 4. Sync child items to pull request status. Idempotent: items already in the target state or
    #    in a terminal state are left untouched.
    $statusGroups = @(
        [pscustomobject]@{ Status = 'completed'; PullRequests = $completed }
        [pscustomobject]@{ Status = 'abandoned'; PullRequests = $abandoned }
    )
    foreach ($group in $statusGroups) {
        $targetState = Get-TaskStateForPrStatus -PrStatus $group.Status
        foreach ($pr in $group.PullRequests) {
            $linked = @(Get-PrLinkedWorkItemId -Headers $headers -CollectionUri $collectionUri -Project $project -RepositoryId $repositoryId -PullRequestId $pr.pullRequestId)
            foreach ($id in $linked) {
                $currentState = Get-WorkItemState -Headers $headers -CollectionUri $collectionUri -Project $project -Id $id
                if (-not (Test-ShouldSetState -CurrentState $currentState -TargetState $targetState)) {
                    Write-Host "Work item #$id is already '$currentState' - skipping (PR #$($pr.pullRequestId) $($group.Status))"
                    continue
                }
                if ($WhatIf) {
                    Write-Host "[WhatIf] Would set work item #$id to '$targetState' (PR #$($pr.pullRequestId) $($group.Status))"
                }
                else {
                    Set-WorkItemState -Headers $headers -CollectionUri $collectionUri -Project $project -Id $id -State $targetState | Out-Null
                    Write-Host "Work item #$id set to '$targetState' (PR #$($pr.pullRequestId) $($group.Status))"
                }
            }
        }
    }

    Write-Host 'Work item governance complete.'
}

# Dot-sourcing (both the Pester tests and the PowerShell@2 task) only loads the functions.
# The caller invokes the entry point explicitly: `. New-RenovateWorkItems.ps1; Invoke-Main`.
# Do not add a self-invoking guard here: PowerShell@2 dot-sources the script, so a guard on
# $MyInvocation.InvocationName would make the pipeline step succeed while doing nothing.
