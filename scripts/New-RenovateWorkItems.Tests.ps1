BeforeAll {
    $script:ScriptUnderTest = Join-Path $PSScriptRoot 'New-RenovateWorkItems.ps1'
    # Dot-sourcing loads the functions without running the entry point.
    . $script:ScriptUnderTest
}

Describe 'Pure helpers' {

    Context 'Get-RenovatePrLevel' {
        It 'reads the level from the pull request title' {
            Get-RenovatePrLevel -Title 'dotnet-sdk patch' -SourceBranch '' | Should -Be 'patch'
        }
        It 'falls back to the source branch' {
            Get-RenovatePrLevel -Title 'Update dependency x' -SourceBranch 'refs/heads/renovate/minor-x' | Should -Be 'minor'
        }
        It 'returns update when no level is present' {
            Get-RenovatePrLevel -Title 'Update dependency x to v2' -SourceBranch 'refs/heads/renovate/x' | Should -Be 'update'
        }
    }

    Context 'Format-RenovateTaskTitle' {
        It 'contains the pull request id and title' {
            Format-RenovateTaskTitle -PullRequestId 42 -PrTitle 'Update dotnet-sdk' | Should -Be 'Renovate PR #42: Update dotnet-sdk'
        }
    }

    Context 'Select-PrsNeedingTask (idempotency)' {
        It 'excludes pull requests that already have a work item' {
            $prs = @(
                [pscustomobject]@{ pullRequestId = 1 },
                [pscustomobject]@{ pullRequestId = 2 },
                [pscustomobject]@{ pullRequestId = 3 }
            )
            $result = Select-PrsNeedingTask -PullRequests $prs -PrIdsWithTask @(2)
            $result.pullRequestId | Should -Be @(1, 3)
        }
        It 'returns everything when no work items exist yet' {
            $prs = @([pscustomobject]@{ pullRequestId = 1 })
            (Select-PrsNeedingTask -PullRequests $prs -PrIdsWithTask @()).Count | Should -Be 1
        }
        It 'returns nothing for an empty pull request list' {
            @(Select-PrsNeedingTask -PullRequests @() -PrIdsWithTask @()).Count | Should -Be 0
        }
    }

    Context 'Get-TaskStateForPrStatus' {
        It 'completed -> Done' { Get-TaskStateForPrStatus -PrStatus 'completed' | Should -Be 'Done' }
        It 'abandoned -> Removed' { Get-TaskStateForPrStatus -PrStatus 'abandoned' | Should -Be 'Removed' }
        It 'active -> $null, leaving the item open' { Get-TaskStateForPrStatus -PrStatus 'active' | Should -BeNullOrEmpty }
    }

    Context 'Test-ShouldSetState (idempotency and safety)' {
        It 'transitions from an open state' { Test-ShouldSetState -CurrentState 'Committed' -TargetState 'Done' | Should -BeTrue }
        It 'does nothing when already in the target state' { Test-ShouldSetState -CurrentState 'Done' -TargetState 'Done' | Should -BeFalse }
        It 'does nothing from a terminal state' { Test-ShouldSetState -CurrentState 'Removed' -TargetState 'Done' | Should -BeFalse }
        It 'does not overwrite Done with Removed' { Test-ShouldSetState -CurrentState 'Done' -TargetState 'Removed' | Should -BeFalse }
    }

    Context 'ConvertTo-PrArtifactUri' {
        It 'encodes project, repository and pull request into a vstfs URI' {
            ConvertTo-PrArtifactUri -ProjectId 'proj' -RepositoryId 'repo' -PullRequestId 7 |
                Should -Be 'vstfs:///Git/PullRequestId/proj%2Frepo%2F7'
        }
    }

    Context 'New-TaskPatchDocument' {
        BeforeAll {
            $script:doc = New-TaskPatchDocument -Title 'T' -AreaPath 'A' -IterationPath 'I' `
                -ParentUrl 'https://example.invalid/_apis/wit/workItems/1' -PrArtifactUri 'vstfs:///Git/PullRequestId/a%2Fb%2F1'
        }
        It 'sets the title' {
            ($doc | Where-Object { $_.path -eq '/fields/System.Title' }).value | Should -Be 'T'
        }
        It 'includes a parent link' {
            $rel = $doc | Where-Object { $_.value -is [hashtable] -and $_.value.ContainsKey('rel') -and $_.value.rel -eq 'System.LinkTypes.Hierarchy-Reverse' }
            $rel.value.url | Should -Be 'https://example.invalid/_apis/wit/workItems/1'
        }
        It 'includes a pull request artifact link' {
            $link = $doc | Where-Object { $_.value -is [hashtable] -and $_.value.ContainsKey('rel') -and $_.value.rel -eq 'ArtifactLink' }
            $link.value.url | Should -Be 'vstfs:///Git/PullRequestId/a%2Fb%2F1'
            $link.value.attributes.name | Should -Be 'Pull Request'
        }
        It 'omits the area path when none is supplied, so the project default applies' {
            $bare = New-TaskPatchDocument -Title 'T' -IterationPath 'I' `
                -ParentUrl 'https://example.invalid/_apis/wit/workItems/1' -PrArtifactUri 'vstfs:///Git/PullRequestId/a%2Fb%2F1'
            @($bare | Where-Object { $_.path -eq '/fields/System.AreaPath' }).Count | Should -Be 0
        }
    }
}

Describe 'Invoke-Main with mocked REST' {

    BeforeEach {
        # Placeholder organisation on purpose: these values only have to round-trip through the code.
        $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/<org>/'
        $env:SYSTEM_TEAMPROJECT = 'demo-project'
        $env:SYSTEM_TEAMPROJECTID = 'proj-guid'
        $env:BUILD_REPOSITORY_ID = 'repo-guid'
        $env:SYSTEM_ACCESSTOKEN = 'fake-token'

        Mock -CommandName Get-CurrentIterationPath -MockWith { 'demo-project\demo-team\Iteration 1' }
        Mock -CommandName New-WorkItem -MockWith { [pscustomobject]@{ id = 999 } }
        Mock -CommandName Set-WorkItemState -MockWith { }
        Mock -CommandName Get-WorkItemState -MockWith { 'Committed' }
    }

    AfterEach {
        foreach ($v in 'SYSTEM_COLLECTIONURI', 'SYSTEM_TEAMPROJECT', 'SYSTEM_TEAMPROJECTID', 'BUILD_REPOSITORY_ID', 'SYSTEM_ACCESSTOKEN') {
            Remove-Item "env:$v" -ErrorAction SilentlyContinue
        }
    }

    It 'creates the run item plus one child per new active pull request' {
        Mock -CommandName Get-RenovatePullRequest -MockWith {
            @(
                [pscustomobject]@{ pullRequestId = 1; title = 'Update a'; status = 'active'; sourceRefName = 'refs/heads/renovate/a' },
                [pscustomobject]@{ pullRequestId = 2; title = 'Update b'; status = 'active'; sourceRefName = 'refs/heads/renovate/b' }
            )
        }
        Mock -CommandName Get-PrLinkedWorkItemId -MockWith { @() }

        Invoke-Main

        Should -Invoke New-WorkItem -Exactly 3
        Should -Invoke New-WorkItem -Exactly 1 -ParameterFilter { $Type -eq 'Product Backlog Item' }
        Should -Invoke New-WorkItem -Exactly 2 -ParameterFilter { $Type -eq 'Task' }
    }

    It 'creates the run item directly in the configured state' {
        Mock -CommandName Get-RenovatePullRequest -MockWith { @() }
        Mock -CommandName Get-PrLinkedWorkItemId -MockWith { @() }

        Invoke-Main

        Should -Invoke New-WorkItem -Exactly 1 -ParameterFilter {
            $Type -eq 'Product Backlog Item' -and
            (@($PatchDocument | Where-Object { $_.path -eq '/fields/System.State' }).value) -eq 'Committed'
        }
    }

    It 'is idempotent: no child item for a pull request that is already linked' {
        Mock -CommandName Get-RenovatePullRequest -MockWith {
            @(
                [pscustomobject]@{ pullRequestId = 1; title = 'Update a'; status = 'active'; sourceRefName = 'refs/heads/renovate/a' },
                [pscustomobject]@{ pullRequestId = 2; title = 'Update b'; status = 'active'; sourceRefName = 'refs/heads/renovate/b' }
            )
        }
        Mock -CommandName Get-PrLinkedWorkItemId -MockWith { @(555) } -ParameterFilter { $PullRequestId -eq 1 }
        Mock -CommandName Get-PrLinkedWorkItemId -MockWith { @() } -ParameterFilter { $PullRequestId -eq 2 }

        Invoke-Main

        Should -Invoke New-WorkItem -Exactly 1 -ParameterFilter { $Type -eq 'Task' }
    }

    It 'moves items of abandoned pull requests to Removed' {
        Mock -CommandName Get-RenovatePullRequest -MockWith {
            @(
                [pscustomobject]@{ pullRequestId = 9; title = 'Update c'; status = 'abandoned'; sourceRefName = 'refs/heads/renovate/c' }
            )
        }
        Mock -CommandName Get-PrLinkedWorkItemId -MockWith { @(777) } -ParameterFilter { $PullRequestId -eq 9 }

        Invoke-Main

        Should -Invoke Set-WorkItemState -Exactly 1 -ParameterFilter { $Id -eq 777 -and $State -eq 'Removed' }
        Should -Invoke New-WorkItem -Exactly 1 -ParameterFilter { $Type -eq 'Product Backlog Item' }
        # No per-pull-request item was created, so a placeholder must appear instead.
        Should -Invoke New-WorkItem -Exactly 1 -ParameterFilter {
            $Type -eq 'Task' -and
            (@($PatchDocument | Where-Object { $_.path -eq '/fields/System.Title' }).value) -eq 'No pull requests created in this run'
        }
    }

    It 'moves items of completed pull requests to Done as a safety net' {
        Mock -CommandName Get-RenovatePullRequest -MockWith {
            @(
                [pscustomobject]@{ pullRequestId = 11; title = 'Update d'; status = 'completed'; sourceRefName = 'refs/heads/renovate/d' }
            )
        }
        Mock -CommandName Get-PrLinkedWorkItemId -MockWith { @(888) } -ParameterFilter { $PullRequestId -eq 11 }

        Invoke-Main

        Should -Invoke Set-WorkItemState -Exactly 1 -ParameterFilter { $Id -eq 888 -and $State -eq 'Done' }
    }

    It 'is idempotent: leaves an item that is already Done untouched' {
        Mock -CommandName Get-RenovatePullRequest -MockWith {
            @(
                [pscustomobject]@{ pullRequestId = 11; title = 'Update d'; status = 'completed'; sourceRefName = 'refs/heads/renovate/d' }
            )
        }
        Mock -CommandName Get-PrLinkedWorkItemId -MockWith { @(888) } -ParameterFilter { $PullRequestId -eq 11 }
        Mock -CommandName Get-WorkItemState -MockWith { 'Done' } -ParameterFilter { $Id -eq 888 }

        Invoke-Main

        Should -Invoke Set-WorkItemState -Exactly 0
    }

    It 'publishes the run item id as an output variable' {
        Mock -CommandName Get-RenovatePullRequest -MockWith { @() }
        Mock -CommandName Get-PrLinkedWorkItemId -MockWith { @() }
        Mock -CommandName Write-Host -MockWith { }

        Invoke-Main

        Should -Invoke Write-Host -Exactly 1 -ParameterFilter {
            "$Object" -eq '##vso[task.setvariable variable=RenovateRunItemId;isOutput=true]999'
        }
    }

    It 'writes nothing and publishes no run item id in a WhatIf run' {
        Mock -CommandName Get-RenovatePullRequest -MockWith { @() }
        Mock -CommandName Get-PrLinkedWorkItemId -MockWith { @() }
        Mock -CommandName Write-Host -MockWith { }

        Invoke-Main -WhatIf

        Should -Invoke New-WorkItem -Exactly 0
        Should -Invoke Set-WorkItemState -Exactly 0
        Should -Invoke Write-Host -Exactly 0 -ParameterFilter { "$Object" -like '*RenovateRunItemId*' }
    }

    It 'creates a run item plus a placeholder when there are no pull requests' {
        Mock -CommandName Get-RenovatePullRequest -MockWith { @() }
        Mock -CommandName Get-PrLinkedWorkItemId -MockWith { @() }

        Invoke-Main

        Should -Invoke New-WorkItem -Exactly 1 -ParameterFilter { $Type -eq 'Product Backlog Item' }
        Should -Invoke New-WorkItem -Exactly 1 -ParameterFilter {
            $Type -eq 'Task' -and
            (@($PatchDocument | Where-Object { $_.path -eq '/fields/System.Title' }).value) -eq 'No pull requests created in this run'
        }
    }
}

Describe 'Get-RenovatePullRequest pagination and time window' {

    $script:baseArgs = @{
        Headers       = @{ Authorization = 'Bearer x' }
        CollectionUri = 'https://dev.azure.com/<org>/'
        Project       = 'demo-project'
        RepositoryId  = 'repo-guid'
        BranchPrefix  = 'refs/heads/renovate/'
    }

    It 'keeps paging until a page smaller than PageSize comes back' {
        # Page 1 is full (2 items), page 2 has 1 item, so paging stops there.
        Mock -CommandName Invoke-RestMethod -MockWith {
            if ($Uri -match 'skip=0') {
                @{ value = @(
                        [pscustomobject]@{ pullRequestId = 1; sourceRefName = 'refs/heads/renovate/a' },
                        [pscustomobject]@{ pullRequestId = 2; sourceRefName = 'refs/heads/renovate/b' }
                    ) }
            }
            else {
                @{ value = @([pscustomobject]@{ pullRequestId = 3; sourceRefName = 'refs/heads/renovate/c' }) }
            }
        }

        $result = Get-RenovatePullRequest @baseArgs -Status 'active' -PageSize 2

        $result.Count | Should -Be 3
        Should -Invoke Invoke-RestMethod -Exactly 2
    }

    It 'filters out pull requests outside the branch prefix' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            @{ value = @(
                    [pscustomobject]@{ pullRequestId = 1; sourceRefName = 'refs/heads/renovate/a' },
                    [pscustomobject]@{ pullRequestId = 2; sourceRefName = 'refs/heads/feature/x' }
                ) }
        }

        $result = Get-RenovatePullRequest @baseArgs -Status 'active' -PageSize 100

        @($result).pullRequestId | Should -Be 1
    }

    It 'adds a time window for closed statuses' {
        Mock -CommandName Invoke-RestMethod -MockWith { @{ value = @() } }

        Get-RenovatePullRequest @baseArgs -Status 'abandoned' -MinClosedTime ([datetime]'2026-08-01') -PageSize 100 | Out-Null

        Should -Invoke Invoke-RestMethod -Exactly 1 -ParameterFilter {
            $Uri -match 'searchCriteria\.status=abandoned' -and
            $Uri -match 'searchCriteria\.queryTimeRangeType=Closed' -and
            $Uri -match 'searchCriteria\.minTime='
        }
    }

    It 'adds no time window without MinClosedTime' {
        Mock -CommandName Invoke-RestMethod -MockWith { @{ value = @() } }

        Get-RenovatePullRequest @baseArgs -Status 'active' -PageSize 100 | Out-Null

        Should -Invoke Invoke-RestMethod -Exactly 1 -ParameterFilter { $Uri -notmatch 'minTime' }
    }
}
