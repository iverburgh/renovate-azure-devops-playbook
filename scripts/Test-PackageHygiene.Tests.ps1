BeforeAll {
    $script:GuardScript = Join-Path $PSScriptRoot 'Test-PackageHygiene.ps1'
    $script:ExampleAllowlist = Join-Path $PSScriptRoot '..' 'config' 'package-hygiene-allowlist.json'

    # Central file layout is fixed on purpose: the n-th PackageVersion sits on line 6 + n.
    function Get-CentralProps {
        param([System.Collections.IDictionary]$Versions, [string]$Extra = '')
        $lines = @(
            '<Project>'
            '  <PropertyGroup>'
            '    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>'
            '    <CentralPackageTransitivePinningEnabled>true</CentralPackageTransitivePinningEnabled>'
            '  </PropertyGroup>'
            '  <ItemGroup>'
        )
        foreach ($name in $Versions.Keys) { $lines += "    <PackageVersion Include=""$name"" Version=""$($Versions[$name])"" />" }
        $lines += '  </ItemGroup>'
        if ($Extra) { $lines += $Extra }
        $lines += '</Project>'
        ($lines -join "`n") + "`n"
    }

    function Get-ProjectXml {
        param([string[]]$Reference = @(), [string]$Extra = '')
        $lines = @(
            '<Project Sdk="Microsoft.NET.Sdk">'
            '  <PropertyGroup>'
            '    <TargetFramework>net8.0</TargetFramework>'
            '  </PropertyGroup>'
            '  <ItemGroup>'
        )
        foreach ($name in $Reference) { $lines += "    <PackageReference Include=""$name"" />" }
        $lines += '  </ItemGroup>'
        if ($Extra) { $lines += $Extra }
        $lines += '</Project>'
        ($lines -join "`n") + "`n"
    }

    # A lock file section where Newtonsoft.Json is a central transitive pin requested by one parent
    # per entry in ParentRequest. Serilog is the direct reference.
    function Get-PinSection {
        param([string[]]$ParentRequest = @('13.0.1'), [string]$Pin = '13.0.3')
        $section = [ordered]@{}
        $i = 0
        foreach ($request in $ParentRequest) {
            $i++
            $section["Parent.Package$i"] = [ordered]@{ type = 'Transitive'; resolved = '1.0.0'; dependencies = [ordered]@{ 'Newtonsoft.Json' = $request } }
        }
        $section['Serilog'] = [ordered]@{ type = 'Direct'; requested = '[3.1.1, )'; resolved = '3.1.1' }
        $section['Newtonsoft.Json'] = [ordered]@{ type = 'CentralTransitive'; requested = "[$Pin, )"; resolved = $Pin }
        $section
    }

    function Get-LockJson {
        param([System.Collections.IDictionary]$Sections)
        ConvertTo-Json -InputObject ([ordered]@{ version = 2; dependencies = $Sections }) -Depth 10
    }

    function Get-CleanFiles {
        [ordered]@{
            'Directory.Packages.props'          = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3' })
            'Directory.Build.props'             = "<Project>`n  <PropertyGroup>`n    <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>`n  </PropertyGroup>`n</Project>`n"
            'src/Orders.Api/Orders.Api.csproj'  = Get-ProjectXml -Reference 'Serilog'
            'src/Orders.Api/packages.lock.json' = Get-LockJson ([ordered]@{ 'net8.0' = (Get-PinSection) })
        }
    }

    function Write-FixtureFile {
        param([string]$Root, [System.Collections.IDictionary]$Files)
        foreach ($relative in $Files.Keys) {
            $path = Join-Path $Root $relative
            [void][System.IO.Directory]::CreateDirectory((Split-Path $path -Parent))
            $content = $Files[$relative]
            if ($content -is [byte[]]) { [System.IO.File]::WriteAllBytes($path, $content) }
            else { [System.IO.File]::WriteAllText($path, $content) }
        }
    }

    function New-FixtureRepo {
        param(
            [System.Collections.IDictionary]$Files,
            [System.Collections.IDictionary]$Untracked = @{},
            [switch]$NoGit
        )
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][System.IO.Directory]::CreateDirectory($root)
        Write-FixtureFile -Root $root -Files $Files
        if (-not $NoGit) {
            git -C $root -c init.defaultBranch=main init --quiet 2>$null
            git -C $root -c core.autocrlf=false -c core.safecrlf=false add --all 2>$null
        }
        Write-FixtureFile -Root $root -Files $Untracked
        $root
    }

    function Invoke-Guard {
        param([string]$Root, [hashtable]$Parameters = @{})
        $raw = & $script:GuardScript -RepositoryRoot $Root @Parameters *>&1
        $code = $LASTEXITCODE
        $lines = @($raw | ForEach-Object { "$_" })
        [pscustomobject]@{ ExitCode = $code; Lines = $lines; Text = $lines -join "`n" }
    }

    function Get-Finding {
        param([object]$Result, [string]$Rule)
        @($Result.Lines | Where-Object { $_ -match "\[$([regex]::Escape($Rule))\]" })
    }

    function Get-TreeSnapshot {
        param([string]$Root)
        $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
            Sort-Object FullName
        ($files | ForEach-Object { "$($_.FullName.Substring($Root.Length))=$((Get-FileHash -LiteralPath $_.FullName).Hash)" }) -join "`n"
    }
}

Describe 'a clean repository' {

    It 'passes without findings' {
        $root = New-FixtureRepo (Get-CleanFiles)
        $result = Invoke-Guard $root
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match '0 error\(s\), 0 warning\(s\)'
        $result.Text | Should -Not -Match 'ERROR:|WARNING:'
    }

    It 'passes in pipeline mode without logging commands and without touching files' {
        $root = New-FixtureRepo (Get-CleanFiles)
        $before = Get-TreeSnapshot $root
        $result = Invoke-Guard $root @{ Ci = $true }
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Not -Match '##vso\[task\.logissue'
        Get-TreeSnapshot $root | Should -Be $before
    }
}

Describe 'dead-entry' {

    It 'fails on a PackageVersion that nothing references or resolves' {
        $files = Get-CleanFiles
        $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3'; Polly = '8.4.1' })
        $result = Invoke-Guard (New-FixtureRepo $files)
        $result.ExitCode | Should -Be 1
        $finding = @(Get-Finding $result 'dead-entry')
        $finding | Should -HaveCount 1
        $finding[0] | Should -BeLike "ERROR: Directory.Packages.props:9: *'Polly' (8.4.1)*"
    }

    It 'counts a reference from a props file' {
        $files = Get-CleanFiles
        $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3'; 'Microsoft.SourceLink.GitHub' = '8.0.0' })
        $files['Directory.Build.props'] = "<Project>`n  <ItemGroup>`n    <PackageReference Include=""Microsoft.SourceLink.GitHub"" PrivateAssets=""all"" />`n  </ItemGroup>`n</Project>`n"
        $result = Invoke-Guard (New-FixtureRepo $files)
        $result.ExitCode | Should -Be 0
    }

    It 'counts a GlobalPackageReference and semicolon-separated lists' {
        $files = Get-CleanFiles
        $global = '  <ItemGroup>' + "`n" + '    <GlobalPackageReference Include="StyleCop.Analyzers" Version="1.1.118" />' + "`n" + '  </ItemGroup>'
        $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3'; Polly = '8.4.1'; Dapper = '2.1.35' }) -Extra $global
        $files['src/Orders.Api/Orders.Api.csproj'] = Get-ProjectXml -Reference 'Serilog', 'Polly; Dapper'
        $result = Invoke-Guard (New-FixtureRepo $files)
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Not -Match 'cpm-bypass'
    }

    It 'does not count PackageReference Update as a reference' {
        $files = Get-CleanFiles
        $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3'; Polly = '8.4.1' })
        $files['Directory.Build.props'] = "<Project>`n  <ItemGroup>`n    <PackageReference Update=""Polly"" PrivateAssets=""all"" />`n  </ItemGroup>`n</Project>`n"
        $result = Invoke-Guard (New-FixtureRepo $files)
        $result.ExitCode | Should -Be 1
        Get-Finding $result 'dead-entry' | Should -HaveCount 1
    }

    It 'ignores untracked projects and anything below bin or obj' {
        $files = Get-CleanFiles
        $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3'; Polly = '8.4.1' })
        $files['src/Orders.Api/obj/Orders.Api.csproj.nuget.g.props'] = Get-ProjectXml -Reference 'Polly'
        $untracked = @{ 'src/Scratch/Scratch.csproj' = (Get-ProjectXml -Reference 'Polly') }
        $result = Invoke-Guard (New-FixtureRepo $files -Untracked $untracked)
        $result.ExitCode | Should -Be 1
        Get-Finding $result 'dead-entry' | Should -HaveCount 1
    }

    It 'reports conditional duplicates of one package once' {
        $files = Get-CleanFiles
        $conditional = @(
            '  <ItemGroup Condition="''$(TargetFramework)'' == ''net8.0''">'
            '    <PackageVersion Include="Polly" Version="8.4.1" />'
            '  </ItemGroup>'
            '  <ItemGroup Condition="''$(TargetFramework)'' == ''net6.0''">'
            '    <PackageVersion Include="Polly" Version="7.2.4" />'
            '  </ItemGroup>'
        ) -join "`n"
        $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3' }) -Extra $conditional
        $result = Invoke-Guard (New-FixtureRepo $files)
        $result.ExitCode | Should -Be 1
        Get-Finding $result 'dead-entry' | Should -HaveCount 1
    }
}

Describe 'orphaned-lock-file' {

    It 'fails on a lock file without a project in its folder and does not take it as evidence' {
        $files = Get-CleanFiles
        $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3'; Polly = '8.4.1' })
        $files['src/Old.Service/packages.lock.json'] = Get-LockJson ([ordered]@{ 'net8.0' = [ordered]@{ Polly = [ordered]@{ type = 'Direct'; requested = '[8.4.1, )'; resolved = '8.4.1' } } })
        $result = Invoke-Guard (New-FixtureRepo $files)
        $result.ExitCode | Should -Be 1
        $orphan = @(Get-Finding $result 'orphaned-lock-file')
        $orphan | Should -HaveCount 1
        $orphan[0] | Should -BeLike 'ERROR: src/Old.Service/packages.lock.json: *'
        Get-Finding $result 'dead-entry' | Should -HaveCount 1
    }

    It 'accepts any *proj file as the project, such as a database project' {
        $files = Get-CleanFiles
        $files['src/Orders.Database/Orders.Database.sqlproj'] = '<Project Sdk="Microsoft.Build.Sql"></Project>'
        $files['src/Orders.Database/packages.lock.json'] = Get-LockJson ([ordered]@{ 'net8.0' = [ordered]@{} })
        $result = Invoke-Guard (New-FixtureRepo $files)
        $result.ExitCode | Should -Be 0
    }

    It 'ignores an untracked lock file' {
        $untracked = @{ 'src/Old.Service/packages.lock.json' = (Get-LockJson ([ordered]@{ 'net8.0' = [ordered]@{} })) }
        $result = Invoke-Guard (New-FixtureRepo (Get-CleanFiles) -Untracked $untracked)
        $result.ExitCode | Should -Be 0
    }

    It 'fails on a lock file that is not a NuGet lock file' -TestCases @(
        @{ Content = '{ not json' }
        @{ Content = '{ "version": 2 }' }
    ) {
        param($Content)
        $files = Get-CleanFiles
        $files['src/Orders.Api/packages.lock.json'] = $Content
        $result = Invoke-Guard (New-FixtureRepo $files)
        $result.ExitCode | Should -Be 1
        $invalid = @(Get-Finding $result 'invalid-lock-file')
        $invalid | Should -HaveCount 1
        $invalid[0] | Should -Match 'dotnet restore --force-evaluate'
    }
}

Describe 'pins' {

    BeforeAll {
        function Invoke-PinCase {
            param([System.Collections.IDictionary]$Sections, [string]$Pin = '13.0.3')
            $files = Get-CleanFiles
            $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = $Pin })
            $files['src/Orders.Api/packages.lock.json'] = Get-LockJson $Sections
            Invoke-Guard (New-FixtureRepo $files)
        }
    }

    It 'warns when the pin equals what a parent already requests' {
        $result = Invoke-PinCase ([ordered]@{ 'net8.0' = (Get-PinSection -ParentRequest '13.0.3') })
        $result.ExitCode | Should -Be 0
        $warning = @(Get-Finding $result 'pin-without-effect')
        $warning | Should -HaveCount 1
        $warning[0] | Should -BeLike 'WARNING: Directory.Packages.props:8: *'
    }

    It 'compares against the highest request of all parents' {
        $result = Invoke-PinCase ([ordered]@{ 'net8.0' = (Get-PinSection -ParentRequest '13.0.1', '[13.0.3, )', '12.0.3') })
        Get-Finding $result 'pin-without-effect' | Should -HaveCount 1
    }

    It 'treats a pin as effective when it raises the version in at least one section' {
        $sections = [ordered]@{
            'net8.0' = (Get-PinSection -ParentRequest '13.0.3')
            'net6.0' = (Get-PinSection -ParentRequest '13.0.1')
        }
        $result = Invoke-PinCase $sections
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Not -Match 'pin-'
    }

    It 'ignores dependencies listed under project references' {
        $section = Get-PinSection -ParentRequest '13.0.1'
        $section['Orders.Contracts'] = [ordered]@{ type = 'Project'; dependencies = [ordered]@{ 'Newtonsoft.Json' = '[13.0.3, )' } }
        $result = Invoke-PinCase ([ordered]@{ 'net8.0' = $section })
        $result.Text | Should -Not -Match 'pin-'
    }

    It 'orders <Pin> above parent request <Request>' -TestCases @(
        @{ Pin = '2.0.0'; Request = '2.0.0-rc.1' }
        @{ Pin = '1.0.0-rc.10'; Request = '1.0.0-rc.9' }
        @{ Pin = '1.0.0-beta'; Request = '1.0.0-2' }
        @{ Pin = '1.0.0-rc.1.1'; Request = '1.0.0-rc.1' }
        @{ Pin = '13.0.3.1'; Request = '13.0.3' }
    ) {
        param($Pin, $Request)
        $result = Invoke-PinCase ([ordered]@{ 'net8.0' = (Get-PinSection -ParentRequest $Request -Pin $Pin) }) -Pin $Pin
        $result.Text | Should -Not -Match 'pin-'
    }

    It 'treats <Pin> and <Request> as the same version' -TestCases @(
        @{ Pin = '3.1-RC.1'; Request = '3.1.0-rc.1' }
        @{ Pin = '13.0.3+build.7'; Request = '[13.0.3]' }
    ) {
        param($Pin, $Request)
        $result = Invoke-PinCase ([ordered]@{ 'net8.0' = (Get-PinSection -ParentRequest $Request -Pin $Pin) }) -Pin $Pin
        Get-Finding $result 'pin-without-effect' | Should -HaveCount 1
    }

    It 'warns that it cannot compare <Case>' -TestCases @(
        @{ Case = 'a floating parent request'; Pin = '13.0.3'; Request = '13.*' }
        @{ Case = 'an exclusive lower bound'; Pin = '13.0.3'; Request = '(13.0.1, )' }
        @{ Case = 'a central version from a property'; Pin = '$(NewtonsoftJsonVersion)'; Request = '13.0.1' }
    ) {
        param($Case, $Pin, $Request)
        $result = Invoke-PinCase ([ordered]@{ 'net8.0' = (Get-PinSection -ParentRequest $Request) }) -Pin $Pin
        $result.ExitCode | Should -Be 0
        Get-Finding $result 'pin-not-comparable' | Should -HaveCount 1
        Get-Finding $result 'pin-without-effect' | Should -HaveCount 0
    }
}

Describe 'cpm-bypass' {

    BeforeAll {
        function Invoke-BypassCase {
            param([string]$Content, [string]$Path = 'src/Orders.Worker/Orders.Worker.csproj', [hashtable]$Parameters = @{})
            $files = Get-CleanFiles
            $files[$Path] = $Content
            Invoke-Guard (New-FixtureRepo $files) $Parameters
        }
    }

    It 'fails when <Property> is false, with the line number' -TestCases @(
        @{ Property = 'ManagePackageVersionsCentrally' }
        @{ Property = 'ImportDirectoryPackagesProps' }
    ) {
        param($Property)
        $content = "<Project Sdk=""Microsoft.NET.Sdk"">`n  <PropertyGroup>`n    <TargetFramework>net8.0</TargetFramework>`n    <$Property> False </$Property>`n  </PropertyGroup>`n</Project>`n"
        $result = Invoke-BypassCase $content
        $result.ExitCode | Should -Be 1
        $bypass = @(Get-Finding $result 'cpm-bypass')
        $bypass | Should -HaveCount 1
        $bypass[0] | Should -BeLike "ERROR: src/Orders.Worker/Orders.Worker.csproj:4: *$Property is set to false*"
    }

    It 'fails on a VersionOverride' {
        $result = Invoke-BypassCase (Get-ProjectXml -Extra '  <ItemGroup>
    <PackageReference Include="Serilog" VersionOverride="2.12.0" />
  </ItemGroup>')
        $result.ExitCode | Should -Be 1
        @(Get-Finding $result 'cpm-bypass')[0] | Should -BeLike "*:8: *'Serilog' sets a VersionOverride '2.12.0'*"
    }

    It 'fails on an inline Version as attribute and as child element' {
        $result = Invoke-BypassCase (Get-ProjectXml -Extra '  <ItemGroup>
    <PackageReference Include="Serilog" Version="3.1.1" />
    <PackageReference Update="Newtonsoft.Json">
      <Version>13.0.3</Version>
    </PackageReference>
  </ItemGroup>')
        $result.ExitCode | Should -Be 1
        $bypass = @(Get-Finding $result 'cpm-bypass')
        $bypass | Should -HaveCount 2
        $bypass -join "`n" | Should -Match "'Newtonsoft.Json' sets an inline Version '13.0.3'"
    }

    It 'finds bypasses in a project with the legacy MSBuild namespace' {
        $content = @'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup>
    <PackageReference Include="Serilog">
      <Version>3.1.1</Version>
    </PackageReference>
  </ItemGroup>
</Project>
'@
        $result = Invoke-BypassCase $content
        @(Get-Finding $result 'cpm-bypass')[0] | Should -BeLike '*:4: *'
    }

    It 'does not report <Case>' -TestCases @(
        @{ Case = 'the property set to true'; Extra = '  <PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup>' }
        @{ Case = 'the word false inside another property'; Extra = '  <PropertyGroup><Description>ManagePackageVersionsCentrally=false</Description></PropertyGroup>' }
        @{ Case = 'an Update without version'; Extra = '  <ItemGroup><PackageReference Update="Serilog" PrivateAssets="all" /></ItemGroup>' }
    ) {
        param($Case, $Extra)
        $result = Invoke-BypassCase (Get-ProjectXml -Reference 'Serilog' -Extra $Extra)
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Not -Match 'cpm-bypass'
    }

    It 'warns about an MSBuild file that is not valid XML and goes on' {
        $result = Invoke-BypassCase '<Project><PropertyGroup></Project>'
        $result.ExitCode | Should -Be 0
        Get-Finding $result 'invalid-msbuild' | Should -HaveCount 1
    }
}

Describe 'allowlist' {

    BeforeAll {
        $script:FunctionsProps = @'
<Project>
  <PropertyGroup Condition="'$(MSBuildProjectName)' == 'WorkerExtensions'">
    <ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally>
  </PropertyGroup>
</Project>
'@
        $script:LegacyProject = @'
<Project ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" Version="12.0.3" />
  </ItemGroup>
</Project>
'@

        function Invoke-AllowlistCase {
            param(
                [System.Collections.IDictionary]$Extra,
                [AllowNull()][object]$Allowlist,
                [string]$AllowlistFile = 'config/package-hygiene-allowlist.json',
                [hashtable]$Parameters = @{}
            )
            $files = Get-CleanFiles
            foreach ($key in $Extra.Keys) { $files[$key] = $Extra[$key] }
            if ($null -ne $Allowlist) {
                $files[$AllowlistFile] = if ($Allowlist -is [string]) { $Allowlist } else { ConvertTo-Json -InputObject $Allowlist -Depth 5 }
            }
            Invoke-Guard (New-FixtureRepo $files) $Parameters
        }
    }

    It 'covers a bypass under the listed condition, whatever the whitespace' {
        $allowlist = @{ cpmBypass = @(@{ path = 'src/Functions/Directory.Build.props'; condition = "'`$(MSBuildProjectName)'   ==  'WorkerExtensions'"; reason = 'Generated project.' }) }
        $result = Invoke-AllowlistCase @{ 'src/Functions/Directory.Build.props' = $script:FunctionsProps } $allowlist
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match '0 error\(s\), 0 warning\(s\)'
    }

    It 'does not cover a bypass under another condition and reports the entry as stale' {
        $allowlist = @{ cpmBypass = @(@{ path = 'src/Functions/Directory.Build.props'; condition = "'`$(MSBuildProjectName)' == 'Other'"; reason = 'Generated project.' }) }
        $result = Invoke-AllowlistCase @{ 'src/Functions/Directory.Build.props' = $script:FunctionsProps } $allowlist
        $result.ExitCode | Should -Be 1
        @(Get-Finding $result 'cpm-bypass')[0] | Should -Match "under condition '\`$\(MSBuildProjectName\)' == 'WorkerExtensions'"
        Get-Finding $result 'stale-allowlist' | Should -HaveCount 1
    }

    It 'matches <Glob> against <File>' -TestCases @(
        @{ Glob = 'tools/legacy/**'; File = 'tools/legacy/Build.Tasks/Build.Tasks.csproj' }
        @{ Glob = '**/Build.Tasks.csproj'; File = 'Build.Tasks.csproj' }
        @{ Glob = 'tools/*/Build.Tasks/*.csproj'; File = 'tools/legacy/Build.Tasks/Build.Tasks.csproj' }
        @{ Glob = '/TOOLS/legacy/**'; File = 'tools/legacy/Build.Tasks.csproj' }
    ) {
        param($Glob, $File)
        $allowlist = @{ cpmBypass = @(@{ path = $Glob; reason = 'Legacy tooling.' }) }
        $result = Invoke-AllowlistCase @{ $File = $script:LegacyProject } $allowlist
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Not -Match 'stale-allowlist'
    }

    It 'keeps a single * within one folder' {
        $allowlist = @{ cpmBypass = @(@{ path = 'tools/*'; reason = 'Legacy tooling.' }) }
        $result = Invoke-AllowlistCase @{ 'tools/legacy/Build.Tasks.csproj' = $script:LegacyProject } $allowlist
        $result.ExitCode | Should -Be 1
        Get-Finding $result 'stale-allowlist' | Should -HaveCount 1
    }

    It 'warns about an entry that matches nothing, without failing' {
        $allowlist = @{ cpmBypass = @(@{ path = 'src/Removed/**'; reason = 'Project was removed.' }) }
        $result = Invoke-AllowlistCase @{} $allowlist
        $result.ExitCode | Should -Be 0
        @(Get-Finding $result 'stale-allowlist')[0] | Should -BeLike "WARNING: config/package-hygiene-allowlist.json: *'src/Removed/**'*"
    }

    It 'stops on an invalid allowlist: <Case>' -TestCases @(
        @{ Case = 'missing reason'; Content = '{ "cpmBypass": [ { "path": "tools/**" } ] }'; Expected = 'reason' }
        @{ Case = 'empty reason'; Content = '{ "cpmBypass": [ { "path": "tools/**", "reason": "  " } ] }'; Expected = 'reason' }
        @{ Case = 'missing path'; Content = '{ "cpmBypass": [ { "reason": "Why." } ] }'; Expected = 'path' }
        @{ Case = 'unknown entry property'; Content = '{ "cpmBypass": [ { "path": "tools/**", "reason": "Why.", "expires": "soon" } ] }'; Expected = 'expires' }
        @{ Case = 'unknown top-level property'; Content = '{ "cpmBypasses": [] }'; Expected = 'cpmBypasses' }
        @{ Case = 'cpmBypass not an array'; Content = '{ "cpmBypass": { "path": "tools/**" } }'; Expected = 'array' }
        @{ Case = 'condition not a string'; Content = '{ "cpmBypass": [ { "path": "tools/**", "reason": "Why.", "condition": true } ] }'; Expected = 'condition' }
        @{ Case = 'invalid JSON'; Content = '{ "cpmBypass": [ '; Expected = 'not valid JSON' }
    ) {
        param($Case, $Content, $Expected)
        $result = Invoke-AllowlistCase @{} $Content
        $result.ExitCode | Should -Be 1
        $result.Text | Should -Match '\[guard\]'
        $result.Text | Should -Match ([regex]::Escape($Expected))
    }

    It 'accepts $-prefixed comment properties and an empty list' {
        $result = Invoke-AllowlistCase @{} '{ "$comment": "No exceptions yet.", "cpmBypass": [] }'
        $result.ExitCode | Should -Be 0
    }

    It 'fails when an explicit -AllowlistPath does not exist' {
        $result = Invoke-AllowlistCase @{} $null -Parameters @{ AllowlistPath = (Join-Path $TestDrive 'missing.json') }
        $result.ExitCode | Should -Be 1
        $result.Text | Should -Match 'does not exist'
    }

    It 'reads a custom -AllowlistPath' {
        $allowlist = @{ cpmBypass = @(@{ path = 'tools/**'; reason = 'Legacy tooling.' }) }
        $custom = Join-Path $TestDrive "custom-$([guid]::NewGuid().ToString('N')).json"
        [System.IO.File]::WriteAllText($custom, (ConvertTo-Json -InputObject $allowlist -Depth 5))
        $result = Invoke-AllowlistCase @{ 'tools/legacy/Build.Tasks.csproj' = $script:LegacyProject } $null -Parameters @{ AllowlistPath = $custom }
        $result.ExitCode | Should -Be 0
    }

    It 'ships an example allowlist that is valid and matches the bypasses it describes' {
        $extra = [ordered]@{
            'src/Functions/Directory.Build.props'           = $script:FunctionsProps
            'tools/legacy/Build.Tasks/Build.Tasks.csproj'   = $script:LegacyProject
        }
        $result = Invoke-AllowlistCase $extra (Get-Content -LiteralPath $script:ExampleAllowlist -Raw)
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match '0 error\(s\), 0 warning\(s\)'
    }
}

Describe 'output' {

    BeforeAll {
        $script:DeadFiles = Get-CleanFiles
        $script:DeadFiles['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3'; Polly = '8.4.1' })
    }

    It 'writes plain lines locally' {
        $result = Invoke-Guard (New-FixtureRepo $script:DeadFiles)
        $result.Text | Should -Not -Match '##vso'
        $result.Text | Should -Match 'Package guard: 1 error\(s\), 0 warning\(s\)\.'
    }

    It 'writes logging commands with file and line in pipeline mode and fails' {
        $result = Invoke-Guard (New-FixtureRepo $script:DeadFiles) @{ Ci = $true }
        $result.ExitCode | Should -Be 1
        @($result.Lines | Where-Object { $_.StartsWith('##vso[task.logissue type=error;sourcepath=Directory.Packages.props;linenumber=9][dead-entry]') }) | Should -HaveCount 1
    }

    It 'writes warnings as warning logging commands and passes' {
        $files = Get-CleanFiles
        $files['src/Orders.Api/packages.lock.json'] = Get-LockJson ([ordered]@{ 'net8.0' = (Get-PinSection -ParentRequest '13.0.3') })
        $result = Invoke-Guard (New-FixtureRepo $files) @{ Ci = $true }
        $result.ExitCode | Should -Be 0
        @($result.Lines | Where-Object { $_.StartsWith('##vso[task.logissue type=warning;sourcepath=Directory.Packages.props;linenumber=8][pin-without-effect]') }) | Should -HaveCount 1
    }

    It 'escapes file content so it cannot start a logging command' {
        $files = Get-CleanFiles
        $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3'; Polly = "8.4.1&#10;##vso[task.complete result=Succeeded]100%" })
        $result = Invoke-Guard (New-FixtureRepo $files) @{ Ci = $true }
        $result.ExitCode | Should -Be 1
        @($result.Lines | Where-Object { $_.StartsWith('##vso[task.complete') }) | Should -HaveCount 0
        $result.Text | Should -Match '%0A##vso\[task\.complete result=Succeeded\]100%25'
    }
}

Describe '-Fix' {

    BeforeAll {
        function Get-DirtyFiles {
            $files = Get-CleanFiles
            $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; Polly = '8.4.1'; 'Newtonsoft.Json' = '13.0.3'; Dapper = '2.1.35' })
            $files['src/Old.Service/packages.lock.json'] = Get-LockJson ([ordered]@{ 'net8.0' = [ordered]@{} })
            $files
        }
    }

    It 'changes nothing with -WhatIf' {
        $root = New-FixtureRepo (Get-DirtyFiles)
        $before = Get-TreeSnapshot $root
        # A child process, because ShouldProcess writes its "What if" lines straight to the host.
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $script:GuardScript -RepositoryRoot $root -Fix -WhatIf 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match "What if: .*Remove dead PackageVersion 'Polly'"
        Get-TreeSnapshot $root | Should -Be $before
    }

    It 'removes dead entries and orphaned lock files and keeps the rest' {
        $root = New-FixtureRepo (Get-DirtyFiles)
        $result = Invoke-Guard $root @{ Fix = $true }
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match "Removed PackageVersion 'Polly'"
        $result.Text | Should -Match 'Deleted orphaned lock file src/Old.Service/packages.lock.json'
        $result.Text | Should -Match '0 error\(s\), 0 warning\(s\)'
        $central = Get-Content -LiteralPath (Join-Path $root 'Directory.Packages.props') -Raw
        $central | Should -Not -Match 'Polly|Dapper'
        $central | Should -Match 'Include="Serilog"'
        $central | Should -Match 'Include="Newtonsoft.Json"'
        Join-Path $root 'src/Old.Service/packages.lock.json' | Should -Not -Exist
        Join-Path $root 'src/Orders.Api/packages.lock.json' | Should -Exist
    }

    It 'is idempotent: a second run changes nothing' {
        $root = New-FixtureRepo (Get-DirtyFiles)
        (Invoke-Guard $root @{ Fix = $true }).ExitCode | Should -Be 0
        $after = Get-TreeSnapshot $root
        $second = Invoke-Guard $root @{ Fix = $true }
        $second.ExitCode | Should -Be 0
        $second.Text | Should -Not -Match 'Removed|Deleted'
        Get-TreeSnapshot $root | Should -Be $after
    }

    It 'keeps the byte order mark and CRLF line endings' {
        $files = Get-DirtyFiles
        $text = $files['Directory.Packages.props'].Replace("`n", "`r`n")
        $files['Directory.Packages.props'] = [byte[]]([System.Text.UTF8Encoding]::new($true).GetPreamble() + [System.Text.Encoding]::UTF8.GetBytes($text))
        $root = New-FixtureRepo $files
        (Invoke-Guard $root @{ Fix = $true }).ExitCode | Should -Be 0
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root 'Directory.Packages.props'))
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $after = [System.Text.Encoding]::UTF8.GetString($bytes)
        $after | Should -Not -Match 'Polly'
        $after.Replace("`r`n", '') | Should -Not -Match "`n"
    }

    It 'removes an entry written as an element with a child Version' {
        $multiLine = @(
            '  <ItemGroup>'
            '    <!-- Kept: comments around a removed entry stay. -->'
            '    <PackageVersion Include="Polly">'
            '      <Version>8.4.1</Version>'
            '    </PackageVersion>'
            '    <PackageVersion Include="Polly.Extensions" Version="8.4.1" />'
            '  </ItemGroup>'
        ) -join "`n"
        $files = Get-CleanFiles
        $files['Directory.Packages.props'] = Get-CentralProps ([ordered]@{ Serilog = '3.1.1'; 'Newtonsoft.Json' = '13.0.3' }) -Extra $multiLine
        $files['src/Orders.Api/Orders.Api.csproj'] = Get-ProjectXml -Reference 'Serilog', 'Polly.Extensions'
        $root = New-FixtureRepo $files
        $result = Invoke-Guard $root @{ Fix = $true }
        $result.ExitCode | Should -Be 0
        $central = Get-Content -LiteralPath (Join-Path $root 'Directory.Packages.props') -Raw
        $central | Should -Not -Match '"Polly"|<Version>'
        $central | Should -Match 'Include="Polly.Extensions"'
        { [xml]$central } | Should -Not -Throw
    }

    It 'leaves pins without effect alone' {
        $files = Get-CleanFiles
        $files['src/Orders.Api/packages.lock.json'] = Get-LockJson ([ordered]@{ 'net8.0' = (Get-PinSection -ParentRequest '13.0.3') })
        $root = New-FixtureRepo $files
        $before = Get-TreeSnapshot $root
        $result = Invoke-Guard $root @{ Fix = $true }
        $result.ExitCode | Should -Be 0
        Get-Finding $result 'pin-without-effect' | Should -HaveCount 1
        Get-TreeSnapshot $root | Should -Be $before
    }

    It 'cannot be combined with -Ci' {
        $root = New-FixtureRepo (Get-DirtyFiles)
        $before = Get-TreeSnapshot $root
        & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $script:GuardScript -RepositoryRoot $root -Fix -Ci *> $null
        $LASTEXITCODE | Should -Not -Be 0
        Get-TreeSnapshot $root | Should -Be $before
    }
}

Describe 'fatal problems' {

    It 'fails outside a git repository' {
        $result = Invoke-Guard (New-FixtureRepo (Get-CleanFiles) -NoGit)
        $result.ExitCode | Should -Be 1
        $result.Text | Should -Match '\[guard\].*git'
    }

    It 'fails without a root Directory.Packages.props' {
        $files = Get-CleanFiles
        $files.Remove('Directory.Packages.props')
        $result = Invoke-Guard (New-FixtureRepo $files)
        $result.ExitCode | Should -Be 1
        $result.Text | Should -Match '\[guard\].*Directory\.Packages\.props'
    }

    It 'fails when the repository root does not exist' {
        $result = Invoke-Guard (Join-Path $TestDrive 'does-not-exist')
        $result.ExitCode | Should -Be 1
        $result.Text | Should -Match 'does not exist'
    }
}
