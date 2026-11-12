BeforeAll {
    $script:ScriptUnderTest = Join-Path $PSScriptRoot 'New-RenovateTeamsReport.ps1'
    . $script:ScriptUnderTest

    $script:UrlContext = @{
        CollectionUri = 'https://dev.azure.com/<org>/'
        Project       = 'demo-project'
        Repository    = 'demo-repo'
    }

    # Taken verbatim from a real Renovate 44.x run. The skip detection is pinned to this shape on
    # purpose: invented log lines would let the regex drift away from what Renovate actually emits.
    # Note that every line carries BOTH baseBranch= and branch=, which is what makes the negative
    # lookbehind in the branch pattern necessary.
    $script:RealLog = @(
        '2026-09-08T00:12:30.1640305Z DEBUG: Check for closed PR because recreating closed PRs is disabled. (repository=demo-project/demo-repo, baseBranch=main, branch=renovate/bicep-microsoft.dataprotection)'
        '2026-09-08T00:12:31.0000000Z DEBUG: Found closed PR with current title (repository=demo-project/demo-repo, baseBranch=main, branch=renovate/bicep-microsoft.dataprotection)'
        '2026-09-08T00:12:31.5000000Z DEBUG: Closed PR #1234 already exists. Skipping branch. (repository=demo-project/demo-repo, baseBranch=main, branch=renovate/bicep-microsoft.dataprotection)'
        '2026-09-08T00:12:32.0000000Z DEBUG: recreateClosed is true. No need to check for closed PR. (repository=demo-project/demo-repo, baseBranch=main, branch=renovate/nuget)'
    )

    $script:RunStart = [datetime]::Parse('2026-09-15T00:00:00Z').ToUniversalTime()

    function New-TestPr {
        param([int]$Id, [string]$Title, [object]$Created)
        return [pscustomobject]@{ pullRequestId = $Id; title = $Title; creationDate = $Created }
    }

    function Get-CardText {
        param([object]$Card)
        return (($Card.body | ForEach-Object { $_.text }) -join "`n")
    }
}

Describe 'Get-RenovateSkippedBranch' {

    It 'recognises the skip line in a real Renovate log' {
        $result = @(Get-RenovateSkippedBranch -LogLine $script:RealLog)
        $result | Should -HaveCount 1
        $result[0].PullRequestId | Should -Be 1234
        $result[0].Branch | Should -Be 'renovate/bicep-microsoft.dataprotection'
    }

    It 'does not mistake baseBranch for branch' {
        $result = @(Get-RenovateSkippedBranch -LogLine $script:RealLog)
        $result[0].BaseBranch | Should -Be 'main'
        $result[0].Branch | Should -Not -Be 'main'
    }

    It 'ignores lines that are not a skip' {
        $noise = $script:RealLog | Where-Object { $_ -notmatch 'Skipping branch' }
        @(Get-RenovateSkippedBranch -LogLine $noise) | Should -HaveCount 0
    }

    It 'deduplicates the same blockage across base branches' {
        $lines = @(
            'DEBUG: Closed PR #100 already exists. Skipping branch. (repository=demo-project/demo-repo, baseBranch=main, branch=renovate/dotnet-sdk)'
            'DEBUG: Closed PR #100 already exists. Skipping branch. (repository=demo-project/demo-repo, baseBranch=main, branch=renovate/dotnet-sdk)'
        )
        @(Get-RenovateSkippedBranch -LogLine $lines) | Should -HaveCount 1
    }

    It 'keeps different branches apart' {
        $lines = @(
            'DEBUG: Closed PR #100 already exists. Skipping branch. (repository=demo-project/demo-repo, baseBranch=main, branch=renovate/dotnet-sdk)'
            'DEBUG: Closed PR #101 already exists. Skipping branch. (repository=demo-project/demo-repo, baseBranch=main, branch=renovate/bicep)'
        )
        @(Get-RenovateSkippedBranch -LogLine $lines) | Should -HaveCount 2
    }

    It 'returns an empty list for empty or missing input' -TestCases @(
        @{ LogInput = @() }
        @{ LogInput = @('') }
        @{ LogInput = $null }
    ) {
        @(Get-RenovateSkippedBranch -LogLine $LogInput) | Should -HaveCount 0
    }
}

Describe 'Split-RenovatePullRequest' {

    It 'separates new from still open using the run start time' {
        $prs = @(
            New-TestPr -Id 1 -Title 'Update nuget' -Created '2026-09-15T00:10:00Z'
            New-TestPr -Id 2 -Title 'Update mui' -Created '2026-09-01T09:00:00Z'
        )
        $split = Split-RenovatePullRequest -PullRequest $prs -RunStartTime $script:RunStart
        @($split.New).pullRequestId | Should -Be 1
        @($split.Open).pullRequestId | Should -Be 2
    }

    It 'counts a pull request created exactly at the start time as new' {
        $prs = @(New-TestPr -Id 3 -Title 'Update bicep' -Created '2026-09-15T00:00:00Z')
        $split = Split-RenovatePullRequest -PullRequest $prs -RunStartTime $script:RunStart
        @($split.New) | Should -HaveCount 1
    }

    It 'treats a creationDate as a string and as a DateTime alike' {
        # Windows PowerShell returns the ISO string; PowerShell 7 turns it into a DateTime (Kind=Utc).
        $prs = @(
            New-TestPr -Id 5 -Title 'as string' -Created '2026-09-15T00:10:00.127103Z'
            New-TestPr -Id 6 -Title 'as datetime' -Created ([datetime]::Parse('2026-09-15T00:10:00Z').ToUniversalTime())
            New-TestPr -Id 7 -Title 'older datetime' -Created ([datetime]::Parse('2026-09-01T09:00:00Z').ToUniversalTime())
        )
        $split = Split-RenovatePullRequest -PullRequest $prs -RunStartTime $script:RunStart
        @($split.New).pullRequestId | Should -Be @(5, 6)
        @($split.Open).pullRequestId | Should -Be 7
    }

    It 'puts a pull request without a readable creation date under still open' -TestCases @(
        @{ Created = $null }
        @{ Created = 'not-a-date' }
    ) {
        $prs = @(New-TestPr -Id 4 -Title 'Update x' -Created $Created)
        $split = Split-RenovatePullRequest -PullRequest $prs -RunStartTime $script:RunStart
        @($split.Open) | Should -HaveCount 1
        @($split.New) | Should -HaveCount 0
    }

    It 'returns two empty lists when there are no pull requests' {
        $split = Split-RenovatePullRequest -PullRequest @() -RunStartTime $script:RunStart
        @($split.New) | Should -HaveCount 0
        @($split.Open) | Should -HaveCount 0
    }
}

Describe 'Resolve-RenovateBlockingPr' {

    It 'enriches a skipped branch with the title and link of the blocking pull request' {
        $skipped = Get-RenovateSkippedBranch -LogLine $script:RealLog
        $abandoned = @(New-TestPr -Id 1234 -Title 'Update bicep' -Created '2026-09-01T00:00:00Z')

        $result = @(Resolve-RenovateBlockingPr -SkippedBranch $skipped -AbandonedPullRequest $abandoned @UrlContext)
        $result | Should -HaveCount 1
        $result[0].Label | Should -Be '#1234 Update bicep'
        $result[0].Url | Should -Be 'https://dev.azure.com/<org>/demo-project/_git/demo-repo/pullrequest/1234'
    }

    It 'falls back to the branch name but keeps the link built from the log line' {
        $skipped = Get-RenovateSkippedBranch -LogLine $script:RealLog

        $result = @(Resolve-RenovateBlockingPr -SkippedBranch $skipped -AbandonedPullRequest @() @UrlContext)
        $result | Should -HaveCount 1
        $result[0].Label | Should -Be 'renovate/bicep-microsoft.dataprotection'
        $result[0].Url | Should -Be 'https://dev.azure.com/<org>/demo-project/_git/demo-repo/pullrequest/1234'
    }
}

Describe 'New-RenovateRunReport' {

    It 'produces a complete, empty report when there are no pull requests' {
        $report = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() -LogLine $script:RealLog -RunStartTime $script:RunStart @UrlContext
        @($report.New) | Should -HaveCount 0
        @($report.Open) | Should -HaveCount 0
        @($report.Blocking) | Should -HaveCount 1
        $report.BlockingDetermined | Should -BeTrue
    }

    It 'marks blockages as undetermined when the log is missing or empty' -TestCases @(
        @{ Log = $null }
        @{ Log = @() }
        @{ Log = @('', '   ') }
    ) {
        $report = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() -LogLine $Log -RunStartTime $script:RunStart @UrlContext
        $report.BlockingDetermined | Should -BeFalse
        @($report.Blocking) | Should -HaveCount 0
    }

    It 'places every pull request in exactly one section' {
        $prs = @(
            New-TestPr -Id 101 -Title 'Update nuget' -Created '2026-09-15T00:05:00Z'
            New-TestPr -Id 102 -Title 'Update mui' -Created '2026-09-02T00:00:00Z'
            New-TestPr -Id 103 -Title 'Update vitest' -Created '2026-09-03T00:00:00Z'
        )
        $report = New-RenovateRunReport -ActivePullRequest $prs -AbandonedPullRequest @() -LogLine $script:RealLog -RunStartTime $script:RunStart @UrlContext

        @($report.New).PullRequestId | Should -Be 101
        @($report.Open).PullRequestId | Should -Be @(102, 103)
    }

    It 'carries the run status through' {
        $report = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() -LogLine $script:RealLog -RunStartTime $script:RunStart -RunSucceeded $false @UrlContext
        $report.RunSucceeded | Should -BeFalse
    }

    It 'builds a run item link when the id is known' {
        $report = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() -LogLine $script:RealLog -RunStartTime $script:RunStart -RunItemId 4242 @UrlContext
        $report.RunItemUrl | Should -Be 'https://dev.azure.com/<org>/demo-project/_workitems/edit/4242'
    }

    It 'omits the run item link when the id is missing' {
        $report = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() -LogLine $script:RealLog -RunStartTime $script:RunStart @UrlContext
        $report.RunItemUrl | Should -BeNullOrEmpty
    }

    It 'does not throw on incomplete input' {
        { New-RenovateRunReport -ActivePullRequest @($null, [pscustomobject]@{}) -AbandonedPullRequest @($null) -LogLine $null -RunStartTime $script:RunStart @UrlContext } | Should -Not -Throw
    }
}

Describe 'ConvertTo-RenovateAdaptiveCard' {

    BeforeAll {
        $script:FullReport = New-RenovateRunReport `
            -ActivePullRequest @(New-TestPr -Id 101 -Title 'Update nuget' -Created '2026-09-15T00:05:00Z') `
            -AbandonedPullRequest @(New-TestPr -Id 1234 -Title 'Update bicep' -Created '2026-09-01T00:00:00Z') `
            -LogLine $script:RealLog -RunStartTime $script:RunStart -RunItemId 4242 -BuildId 987 -BuildNumber '20260915.1' `
            @UrlContext
    }

    It 'produces a valid Adaptive Card' {
        $card = ConvertTo-RenovateAdaptiveCard -Report $script:FullReport
        $card.type | Should -Be 'AdaptiveCard'
        $card.version | Should -Be '1.4'
        @($card.body).Count | Should -BeGreaterThan 0
    }

    It 'shows all three section headings' {
        $text = Get-CardText (ConvertTo-RenovateAdaptiveCard -Report $script:FullReport)
        $text | Should -Match 'New in this run'
        $text | Should -Match 'Still open'
        $text | Should -Match 'Possibly blocked'
    }

    It 'includes the run item link' {
        $text = Get-CardText (ConvertTo-RenovateAdaptiveCard -Report $script:FullReport)
        $text | Should -Match '\[Run item #4242\]\(https://dev\.azure\.com/<org>/demo-project/_workitems/edit/4242\)'
    }

    It 'mentions each pull request exactly once' {
        $text = Get-CardText (ConvertTo-RenovateAdaptiveCard -Report $script:FullReport)
        ([regex]::Matches($text, '#101\b')).Count | Should -Be 1
    }

    It 'omits the run item link without failing when the id is missing' {
        $report = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() -LogLine $script:RealLog -RunStartTime $script:RunStart @UrlContext
        $text = Get-CardText (ConvertTo-RenovateAdaptiveCard -Report $report)
        $text | Should -Not -Match 'Run item'
    }

    It 'distinguishes an empty section from an undetermined one' {
        $empty = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() -LogLine @('DEBUG: nothing of interest') -RunStartTime $script:RunStart @UrlContext
        $unknown = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() -LogLine $null -RunStartTime $script:RunStart @UrlContext

        (Get-CardText (ConvertTo-RenovateAdaptiveCard -Report $empty)) | Should -Match 'none'
        (Get-CardText (ConvertTo-RenovateAdaptiveCard -Report $unknown)) | Should -Match 'not determined'
        (Get-CardText (ConvertTo-RenovateAdaptiveCard -Report $empty)) | Should -Not -Match 'not determined'
    }

    It 'shows the run status' -TestCases @(
        @{ Succeeded = $true; Expected = 'succeeded' }
        @{ Succeeded = $false; Expected = 'failed' }
    ) {
        $report = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() -LogLine $script:RealLog -RunStartTime $script:RunStart -RunSucceeded $Succeeded @UrlContext
        (Get-CardText (ConvertTo-RenovateAdaptiveCard -Report $report)) | Should -Match "run $Expected"
    }

    It 'omits the help footer by default, so an unconfigured link never renders' {
        $text = Get-CardText (ConvertTo-RenovateAdaptiveCard -Report $script:FullReport)
        $text | Should -Not -Match 'Need help handling'
    }

    It 'appends a clickable footer when a help url is supplied' {
        $card = ConvertTo-RenovateAdaptiveCard -Report $script:FullReport -HelpUrl 'https://example.invalid/runbook' -HelpLinkLabel 'Runbook'
        (Get-CardText $card) | Should -Match '\[Runbook\]\(https://example\.invalid/runbook\)'
    }

    It 'shows the footer on an empty report too' {
        $empty = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() -LogLine $null -RunStartTime $script:RunStart @UrlContext
        $card = ConvertTo-RenovateAdaptiveCard -Report $empty -HelpUrl 'https://example.invalid/runbook'
        (Get-CardText $card) | Should -Match 'Need help handling'
    }

    It 'is serialisable to JSON' {
        { ConvertTo-RenovateAdaptiveCard -Report $script:FullReport | ConvertTo-Json -Depth 10 } | Should -Not -Throw
    }
}

Describe 'ConvertTo-RenovateTeamsMessage' {

    BeforeAll {
        $script:Message = ConvertTo-RenovateTeamsMessage -Card (ConvertTo-RenovateAdaptiveCard -Report $script:FullReport)
    }

    It 'produces the envelope the Teams webhook trigger expects' {
        $script:Message.type | Should -Be 'message'
        @($script:Message.attachments) | Should -HaveCount 1
    }

    It 'wraps the card in an attachment with the adaptive card content type' {
        $attachment = @($script:Message.attachments)[0]
        $attachment.contentType | Should -Be 'application/vnd.microsoft.card.adaptive'
        $attachment.content.type | Should -Be 'AdaptiveCard'
    }

    It 'preserves the card contents' {
        $text = (@($script:Message.attachments)[0].content.body | ForEach-Object { $_.text }) -join "`n"
        $text | Should -Match 'Possibly blocked'
    }

    It 'serialises to JSON with attachments as an array' {
        $json = $script:Message | ConvertTo-Json -Depth 20
        ($json | ConvertFrom-Json).attachments.Count | Should -Be 1
    }
}

Describe 'URL helpers' {

    It 'builds a pull request url without a double slash' {
        Get-RenovatePrUrl -CollectionUri 'https://dev.azure.com/<org>/' -Project 'demo-project' -Repository 'demo-repo' -PullRequestId 1 |
            Should -Be 'https://dev.azure.com/<org>/demo-project/_git/demo-repo/pullrequest/1'
    }

    It 'builds a work item url' {
        Get-RenovateWorkItemUrl -CollectionUri 'https://dev.azure.com/<org>' -Project 'demo-project' -WorkItemId 2 |
            Should -Be 'https://dev.azure.com/<org>/demo-project/_workitems/edit/2'
    }

    It 'builds a build url' {
        Get-RenovateBuildUrl -CollectionUri 'https://dev.azure.com/<org>/' -Project 'demo-project' -BuildId 3 |
            Should -Be 'https://dev.azure.com/<org>/demo-project/_build/results?buildId=3'
    }
}

Describe 'Format-RenovateLink' {

    It 'creates a markdown link' {
        Format-RenovateLink -Label '#1 Update nuget' -Url 'https://example.invalid' | Should -Be '[#1 Update nuget](https://example.invalid)'
    }

    It 'leaves only the label when there is no url' {
        Format-RenovateLink -Label 'renovate/bicep' -Url '' | Should -Be 'renovate/bicep'
    }

    It 'does not break on square brackets in the title' {
        Format-RenovateLink -Label '#1 Update [x]' -Url 'https://example.invalid' | Should -Be '[#1 Update (x)](https://example.invalid)'
    }
}
