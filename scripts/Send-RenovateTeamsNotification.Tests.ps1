BeforeAll {
    $script:ScriptUnderTest = Join-Path $PSScriptRoot 'Send-RenovateTeamsNotification.ps1'
    . $script:ScriptUnderTest

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "renovate-notify-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:TempRoot) { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force }
}

Describe 'Get-RenovateRunSucceeded' {

    It 'maps <Status> onto <Expected>' -TestCases @(
        @{ Status = 'Succeeded'; Expected = $true }
        @{ Status = 'SucceededWithIssues'; Expected = $true }
        @{ Status = 'Failed'; Expected = $false }
        @{ Status = 'Canceled'; Expected = $false }
        @{ Status = ''; Expected = $true }
    ) {
        Get-RenovateRunSucceeded -AgentJobStatus $Status | Should -Be $Expected
    }
}

Describe 'ConvertTo-RenovateId' {

    It 'reads a valid id' {
        ConvertTo-RenovateId -Value '4242' | Should -Be 4242
    }

    It 'returns 0 for <Label>' -TestCases @(
        @{ Label = 'an empty value'; Value = '' }
        @{ Label = 'a missing value'; Value = $null }
        @{ Label = 'an unreadable value'; Value = 'not-a-number' }
        @{ Label = 'zero'; Value = '0' }
        @{ Label = 'a negative number'; Value = '-5' }
    ) {
        ConvertTo-RenovateId -Value $Value | Should -Be 0
    }
}

Describe 'Resolve-RenovateRunStartTime' {

    It 'reads the pipeline start time including its offset' {
        $result = Resolve-RenovateRunStartTime -PipelineStartTime '2026-09-16 00:00:42+00:00'
        $result.ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-09-16T00:00:42'
    }

    It 'converts an offset to UTC' {
        $result = Resolve-RenovateRunStartTime -PipelineStartTime '2026-09-16 02:00:00+02:00'
        $result.ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-09-16T00:00:00'
    }

    It 'falls back to the supplied moment on unreadable input' -TestCases @(
        @{ Value = $null }
        @{ Value = '' }
        @{ Value = 'not-a-date' }
    ) {
        $fallback = [datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime()
        Resolve-RenovateRunStartTime -PipelineStartTime $Value -Fallback $fallback | Should -Be $fallback
    }

    It 'prefers the recorded start of the Renovate job over an unreadable pipeline start time' {
        $result = Resolve-RenovateRunStartTime -RenovateJobStartTime '2026-09-29T00:01:28.1234567Z' -PipelineStartTime '29-9-2026 02:01:25'
        $result.ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-09-29T00:01:28'
    }

    It 'prefers the recorded start over a pipeline start time without an offset' {
        # Without an offset the value is read as UTC: two hours late in Central European summer time.
        $result = Resolve-RenovateRunStartTime -RenovateJobStartTime '2026-09-29T00:01:28.0000000Z' -PipelineStartTime '9/29/2026 2:01:25 AM'
        $result.ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-09-29T00:01:28'
    }

    It 'uses the pipeline start time when the recorded start is <Label>' -TestCases @(
        @{ Label = 'empty'; Value = '' }
        @{ Label = 'missing'; Value = $null }
        @{ Label = 'an unresolved pipeline variable'; Value = '$(renovateRunStartTime)' }
    ) {
        $result = Resolve-RenovateRunStartTime -RenovateJobStartTime $Value -PipelineStartTime '2026-09-16 02:00:00+02:00'
        $result.ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-09-16T00:00:00'
    }

    It 'falls back and says so when no source is usable' {
        $fallback = [datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime()
        $out = @(Resolve-RenovateRunStartTime -RenovateJobStartTime '' -PipelineStartTime 'not-a-date' -Fallback $fallback 6>&1)
        @($out | Where-Object { $_ -is [datetime] }) | Should -Be $fallback
        ($out | Where-Object { $_ -isnot [datetime] }) -join "`n" | Should -Match 'unknown'
    }

    It 'reads the recorded start the same under culture <Culture>' -TestCases @(
        @{ Culture = 'nl-NL' }
        @{ Culture = 'en-US' }
    ) {
        $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]$Culture
            [cultureinfo]::CurrentCulture.Name | Should -Be $Culture
            $result = Resolve-RenovateRunStartTime -RenovateJobStartTime '2026-09-29T00:01:28.0000000Z'
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous
        }
        $result.ToString('yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture) | Should -Be '2026-09-29T00:01:28'
    }
}

Describe 'Get-RenovateRunStatus' {

    It 'prefers an explicitly handed-over status' {
        # In a separate notification job Agent.JobStatus describes that job, not the Renovate run.
        Get-RenovateRunStatus -Explicit 'Failed' -AgentJobStatus 'Succeeded' | Should -Be 'Failed'
    }

    It 'falls back to Agent.JobStatus when nothing was handed over' -TestCases @(
        @{ Value = '' }
        @{ Value = $null }
    ) {
        Get-RenovateRunStatus -Explicit $Value -AgentJobStatus 'Canceled' | Should -Be 'Canceled'
    }
}

Describe 'Read-RenovateLogLine' {

    It 'reads the lines of a populated log file' {
        $path = Join-Path $script:TempRoot 'populated.log'
        Set-Content -LiteralPath $path -Value @('line one', 'line two') -Encoding utf8
        @(Read-RenovateLogLine -Path $path) | Should -HaveCount 2
    }

    It 'returns null for a missing file' {
        Read-RenovateLogLine -Path (Join-Path $script:TempRoot 'does-not-exist.log') | Should -BeNullOrEmpty
    }

    It 'returns null for an empty file' {
        $path = Join-Path $script:TempRoot 'empty.log'
        Set-Content -LiteralPath $path -Value '' -Encoding utf8
        Read-RenovateLogLine -Path $path | Should -BeNullOrEmpty
    }

    It 'returns null for a missing path' -TestCases @(
        @{ Value = '' }
        @{ Value = $null }
    ) {
        Read-RenovateLogLine -Path $Value | Should -BeNullOrEmpty
    }

    It 'yields log content that the report can derive blockages from' {
        $path = Join-Path $script:TempRoot 'skip.log'
        Set-Content -LiteralPath $path -Encoding utf8 -Value @(
            '2026-09-08T00:12:31.5000000Z DEBUG: Closed PR #1234 already exists. Skipping branch. (repository=demo-project/demo-repo, baseBranch=main, branch=renovate/bicep-microsoft.dataprotection)'
        )
        $report = New-RenovateRunReport -ActivePullRequest @() -AbandonedPullRequest @() `
            -LogLine (Read-RenovateLogLine -Path $path) -RunStartTime ([datetime]::UtcNow) `
            -CollectionUri 'https://dev.azure.com/<org>/' -Project 'demo-project' -Repository 'demo-repo'

        $report.BlockingDetermined | Should -BeTrue
        @($report.Blocking) | Should -HaveCount 1
    }
}

Describe 'Send-RenovateTeamsMessage' {

    It 'posts the message as JSON to the webhook' {
        Mock Invoke-RestMethod { }
        Send-RenovateTeamsMessage -WebhookUrl 'https://flow.example.invalid/invoke' -Message @{ type = 'message' } | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Exactly 1 -ParameterFilter { $Method -eq 'Post' -and $Uri -eq 'https://flow.example.invalid/invoke' }
    }

    It 'returns $false when the post fails, without throwing itself' {
        Mock Invoke-RestMethod { throw 'endpoint unreachable' }
        $result = $null
        { $result = Send-RenovateTeamsMessage -WebhookUrl 'https://flow.example.invalid/invoke' -Message @{ type = 'message' } } | Should -Not -Throw
        $result | Should -BeFalse
    }

    It 'reports the failure as an error logissue, so the step turns red' {
        Mock Invoke-RestMethod { throw 'endpoint unreachable' }
        $out = Send-RenovateTeamsMessage -WebhookUrl 'https://flow.example.invalid/invoke' -Message @{ type = 'message' } 6>&1
        ($out -join "`n") | Should -Match '##vso\[task\.logissue type=error\]Notification failed'
    }

    It 'includes the innermost exception, which is where the real reason lives' {
        # Windows PowerShell does not load System.Net.Http by default.
        Add-Type -AssemblyName System.Net.Http
        Mock Invoke-RestMethod {
            $inner = [System.Security.Authentication.AuthenticationException]::new('The remote certificate is invalid.')
            throw [System.Net.Http.HttpRequestException]::new('The SSL connection could not be established, see inner exception.', $inner)
        }
        $out = Send-RenovateTeamsMessage -WebhookUrl 'https://flow.example.invalid/invoke' -Message @{ type = 'message' } 6>&1
        ($out -join "`n") | Should -Match 'The remote certificate is invalid'
    }
}

Describe 'Format-RenovateExceptionChain' {

    It 'joins the whole chain' {
        $inner = [System.InvalidOperationException]::new('deepest cause')
        $outer = [System.Exception]::new('outer layer', $inner)
        $text = Format-RenovateExceptionChain -Exception $outer
        $text | Should -Match 'outer layer'
        $text | Should -Match 'deepest cause'
    }

    It 'handles an exception without an inner one' {
        Format-RenovateExceptionChain -Exception ([System.Exception]::new('just this')) | Should -Match 'just this'
    }

    It 'names the exception type, which distinguishes certificate from network failures' {
        Format-RenovateExceptionChain -Exception ([System.TimeoutException]::new('too slow')) | Should -Match '\[TimeoutException\]'
    }
}

Describe 'Test-RenovateWebhookConfigured' {

    It 'accepts a populated url' {
        Test-RenovateWebhookConfigured -WebhookUrl 'https://flow.example.invalid/invoke' | Should -BeTrue
    }

    It 'rejects <Label>' -TestCases @(
        @{ Label = 'an empty value'; Value = '' }
        @{ Label = 'whitespace only'; Value = '   ' }
        # An undefined pipeline variable arrives as this literal string, not as an empty value.
        @{ Label = 'an unresolved pipeline variable'; Value = '$(RenovateNotificationWebhookUrl)' }
    ) {
        Test-RenovateWebhookConfigured -WebhookUrl $Value | Should -BeFalse
    }
}

Describe 'Invoke-TeamsNotification' {

    It 'sends nothing when the webhook url is <Label>' -TestCases @(
        @{ Label = 'empty'; Value = '' }
        @{ Label = 'an unresolved pipeline variable'; Value = '$(RenovateNotificationWebhookUrl)' }
    ) {
        Mock Invoke-RestMethod { }
        $WebhookUrl = $Value
        Invoke-TeamsNotification -WarningAction SilentlyContinue
        Should -Invoke Invoke-RestMethod -Exactly 0
    }

    Context 'when sending fails' {

        BeforeEach {
            $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/<org>/'
            $env:SYSTEM_TEAMPROJECT = 'demo-project'
            $env:BUILD_REPOSITORY_ID = 'repo-guid'
            $env:BUILD_REPOSITORY_NAME = 'demo-repo'
            $env:SYSTEM_ACCESSTOKEN = 'fake-token'
            Mock Get-RenovatePullRequest { @() }
        }

        AfterEach {
            foreach ($v in 'SYSTEM_COLLECTIONURI', 'SYSTEM_TEAMPROJECT', 'BUILD_REPOSITORY_ID', 'BUILD_REPOSITORY_NAME', 'SYSTEM_ACCESSTOKEN') {
                Remove-Item "env:$v" -ErrorAction SilentlyContinue
            }
        }

        It 'fails the step, so an undelivered notification cannot go unnoticed' {
            Mock Send-RenovateTeamsMessage { $false }
            $WebhookUrl = 'https://flow.example.invalid/invoke'
            { Invoke-TeamsNotification } | Should -Throw '*notification failed*'
        }

        It 'succeeds when the message does arrive' {
            Mock Send-RenovateTeamsMessage { $true }
            $WebhookUrl = 'https://flow.example.invalid/invoke'
            { Invoke-TeamsNotification } | Should -Not -Throw
        }
    }

    Context 'splitting new from still open' {

        BeforeEach {
            $env:SYSTEM_COLLECTIONURI = 'https://dev.azure.com/<org>/'
            $env:SYSTEM_TEAMPROJECT = 'demo-project'
            $env:BUILD_REPOSITORY_ID = 'repo-guid'
            $env:BUILD_REPOSITORY_NAME = 'demo-repo'
            $env:SYSTEM_ACCESSTOKEN = 'fake-token'
            # A notification that runs hours after the Renovate job. One creationDate as an ISO string
            # (as Windows PowerShell returns it), the other as a DateTime (as PowerShell 7 returns it).
            $script:FromThisRun = [pscustomobject]@{ pullRequestId = 201; title = 'Update nuget'; status = 'active'; creationDate = '2026-09-29T00:15:21.127103Z' }
            $script:FromEarlierRun = [pscustomobject]@{ pullRequestId = 101; title = 'Update azdo-tasks'; status = 'active'; creationDate = [datetime]::Parse('2026-09-22T14:40:00Z').ToUniversalTime() }
            Mock Get-RenovatePullRequest { @($script:FromThisRun, $script:FromEarlierRun) } -ParameterFilter { $Status -eq 'active' }
            Mock Get-RenovatePullRequest { @() } -ParameterFilter { $Status -eq 'abandoned' }
            Mock Send-RenovateTeamsMessage { $true }
        }

        AfterEach {
            foreach ($v in 'SYSTEM_COLLECTIONURI', 'SYSTEM_TEAMPROJECT', 'BUILD_REPOSITORY_ID', 'BUILD_REPOSITORY_NAME', 'SYSTEM_ACCESSTOKEN', 'SYSTEM_PIPELINESTARTTIME', 'RENOVATE_RUN_START_TIME') {
                Remove-Item "env:$v" -ErrorAction SilentlyContinue
            }
        }

        It 'lists a pull request from this run as new, even when the pipeline start time is unreadable' {
            $env:RENOVATE_RUN_START_TIME = '2026-09-29T00:01:28.0000000Z'
            $env:SYSTEM_PIPELINESTARTTIME = '29-9-2026 02:01:25'
            $WebhookUrl = 'https://flow.example.invalid/invoke'
            $out = Invoke-TeamsNotification 6>&1
            ($out -join "`n") | Should -Match 'Report: new=1, open=1'
        }

        It 'lists everything as still open, and says so, when the start is unknown' {
            $env:RENOVATE_RUN_START_TIME = ''
            $env:SYSTEM_PIPELINESTARTTIME = 'not-a-date'
            $WebhookUrl = 'https://flow.example.invalid/invoke'
            $out = Invoke-TeamsNotification 6>&1
            ($out -join "`n") | Should -Match 'Report: new=0, open=2'
            ($out -join "`n") | Should -Match 'unknown'
        }
    }
}
