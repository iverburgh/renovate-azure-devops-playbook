#Requires -Version 7.2
<#
.SYNOPSIS
    Package guard: checks central package hygiene in a repository that uses NuGet Central Package
    Management.

.DESCRIPTION
    Reads the root Directory.Packages.props, every git-tracked MSBuild file (*.csproj and other
    *proj files, *.props, *.targets) and every git-tracked packages.lock.json. Untracked files and
    anything below bin/ or obj/ are ignored: the guard judges what a clean checkout contains, which
    is what the pipeline and Renovate see.

    Errors (the run fails):
      - dead-entry          A PackageVersion in the root Directory.Packages.props that no project or
                            props file references directly and no valid lock file resolves.
      - orphaned-lock-file  A packages.lock.json without a project file in the same folder.
      - cpm-bypass          ManagePackageVersionsCentrally=false, ImportDirectoryPackagesProps=false,
                            or a PackageReference with an inline Version or a VersionOverride, unless
                            an allowlist entry covers it.
      - invalid-lock-file   A lock file that is not JSON with a 'dependencies' object.

    Warnings (never fail the run):
      - pin-without-effect  A PackageVersion without a direct reference whose version is, in every
                            lock file section that resolves it, not higher than the highest version a
                            parent package already asks for. NuGet picks that version anyway.
      - pin-not-comparable  The same candidate, but a version or range could not be compared
                            (floating version, exclusive lower bound, unparseable text). The pin is
                            treated as effective.
      - stale-allowlist     An allowlist entry that no longer matches any bypass.
      - invalid-msbuild     An MSBuild file that is not valid XML; it is skipped.

    The guard reads files, it does not evaluate MSBuild. A property set through another property, an
    import from outside the repository or a package name taken from a variable is invisible to it.

    An invalid allowlist (bad JSON, unknown property, missing path or reason) stops the run with an
    error before anything else is checked.

.PARAMETER RepositoryRoot
    Root of the git repository. It must contain the root Directory.Packages.props.

.PARAMETER AllowlistPath
    JSON file with the CPM bypass exceptions. Defaults to config/package-hygiene-allowlist.json below
    the repository root; when that default file is missing the allowlist is empty. A path given
    explicitly must exist. Relative paths resolve against the current location.

.PARAMETER Fix
    Removes dead PackageVersion entries and orphaned lock files, then checks again and reports what
    is left. Honours -WhatIf and -Confirm. Cannot be combined with -Ci: the pipeline only reports.

.PARAMETER Ci
    Writes findings as Azure DevOps logging commands (##vso[task.logissue]), so they appear as
    annotations on the run and on the pull request.

.EXAMPLE
    ./scripts/Test-PackageHygiene.ps1 -RepositoryRoot .

    Reports every finding without changing anything.

.EXAMPLE
    ./scripts/Test-PackageHygiene.ps1 -RepositoryRoot . -Fix -WhatIf

    Shows which dead entries and orphaned lock files -Fix would remove.

.EXAMPLE
    & ./scripts/Test-PackageHygiene.ps1 -RepositoryRoot $(Build.SourcesDirectory) -Ci

    Pipeline mode, as used by pipelines/package-guard.yml.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Check')]
param(
    [Parameter(Mandatory)]
    [string]$RepositoryRoot,

    [string]$AllowlistPath,

    [Parameter(Mandatory, ParameterSetName = 'Fix')]
    [switch]$Fix,

    [Parameter(ParameterSetName = 'Check')]
    [switch]$Ci
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CentralFileName = 'Directory.Packages.props'
$script:DefaultAllowlistPath = 'config/package-hygiene-allowlist.json'
$script:CiOutput = $Ci.IsPresent
$script:VersionRegex = [regex]'^(?<numbers>\d+(?:\.\d+){0,3})(?:-(?<labels>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$'

#region Output

function ConvertTo-LoggingValue {
    <# Escapes text for an Azure DevOps logging command, so file content can never start a new command. #>
    param(
        [AllowEmptyString()]
        [string]$Text,
        [switch]$Property
    )
    $escaped = $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    if ($Property) { $escaped = $escaped.Replace(';', '%3B').Replace(']', '%5D') }
    $escaped
}

function New-Finding {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('error', 'warning')]
        [string]$Severity,
        [Parameter(Mandatory)]
        [string]$Rule,
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$Path = '',
        [int]$Line = 0
    )
    [pscustomobject]@{
        Severity = $Severity
        Rule     = $Rule
        Path     = $Path
        Line     = $Line
        Message  = "[$Rule] $Message"
    }
}

function Write-Finding {
    param(
        [Parameter(Mandatory)]
        [object]$Finding
    )
    if ($script:CiOutput) {
        $properties = "type=$($Finding.Severity)"
        if ($Finding.Path) { $properties += ";sourcepath=$(ConvertTo-LoggingValue $Finding.Path -Property)" }
        if ($Finding.Line -gt 0) { $properties += ";linenumber=$($Finding.Line)" }
        Write-Output "##vso[task.logissue $properties]$(ConvertTo-LoggingValue $Finding.Message)"
        return
    }
    $label = if ($Finding.Severity -eq 'error') { 'ERROR' } else { 'WARNING' }
    $location = if (-not $Finding.Path) { '' }
    elseif ($Finding.Line -gt 0) { "$($Finding.Path):$($Finding.Line): " }
    else { "$($Finding.Path): " }
    Write-Output "${label}: $location$($Finding.Message)"
}

#endregion

#region Versions

function ConvertTo-NuGetVersion {
    <# Parses 1 to 4 numeric parts plus optional prerelease labels and metadata. Returns $null when unparseable. #>
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )
    if (-not $Text) { return $null }
    $match = $script:VersionRegex.Match($Text.Trim())
    if (-not $match.Success) { return $null }
    # Missing parts count as zero, so 3.1 equals 3.1.0.0.
    $numbers = [long[]]::new(4)
    $parts = $match.Groups['numbers'].Value.Split('.')
    for ($i = 0; $i -lt $parts.Count; $i++) { $numbers[$i] = [long]$parts[$i] }
    $labels = [string[]]::new(0)
    if ($match.Groups['labels'].Success) { $labels = [string[]]$match.Groups['labels'].Value.Split('.') }
    [pscustomobject]@{ Numbers = $numbers; Labels = $labels }
}

function Compare-NuGetVersion {
    <# SemVer 2.0 precedence with case-insensitive labels. Returns -1, 0 or 1. #>
    param(
        [Parameter(Mandatory)]
        [object]$Left,
        [Parameter(Mandatory)]
        [object]$Right
    )
    for ($i = 0; $i -lt 4; $i++) {
        $difference = $Left.Numbers[$i].CompareTo($Right.Numbers[$i])
        if ($difference -ne 0) { return [Math]::Sign($difference) }
    }
    $leftLabels = $Left.Labels
    $rightLabels = $Right.Labels
    # A release sorts above every prerelease of the same version.
    if ($leftLabels.Length -eq 0 -or $rightLabels.Length -eq 0) {
        return [Math]::Sign($rightLabels.Length - $leftLabels.Length)
    }
    $count = [Math]::Min($leftLabels.Length, $rightLabels.Length)
    for ($i = 0; $i -lt $count; $i++) {
        $leftNumber = 0L
        $rightNumber = 0L
        $leftIsNumber = [long]::TryParse($leftLabels[$i], [ref]$leftNumber)
        $rightIsNumber = [long]::TryParse($rightLabels[$i], [ref]$rightNumber)
        $difference = if ($leftIsNumber -and $rightIsNumber) { $leftNumber.CompareTo($rightNumber) }
        elseif ($leftIsNumber) { -1 }
        elseif ($rightIsNumber) { 1 }
        else { [string]::Compare($leftLabels[$i], $rightLabels[$i], [System.StringComparison]::OrdinalIgnoreCase) }
        if ($difference -ne 0) { return [Math]::Sign($difference) }
    }
    [Math]::Sign($leftLabels.Length - $rightLabels.Length)
}

function Get-LowerBound {
    <#
    .SYNOPSIS
        Returns the inclusive lower bound of a version or range: '1.0.0', '[1.0.0, )', '[1.0.0]'.
        Returns $null for an exclusive or missing lower bound, a floating version or unparseable text.
    #>
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Range
    )
    if (-not $Range) { return $null }
    $text = $Range.Trim()
    if ($text.StartsWith('(')) { return $null }
    if ($text.StartsWith('[')) {
        if (-not ($text.EndsWith(']') -or $text.EndsWith(')'))) { return $null }
        $text = $text.Substring(1, $text.Length - 2).Split(',')[0]
    }
    ConvertTo-NuGetVersion $text
}

#endregion

#region Files

function Get-TrackedFile {
    <# Returns repository-relative paths (forward slashes) of tracked files that exist, outside bin/ and obj/. #>
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )
    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        # -z separates paths with NUL and never quotes them, whatever characters they contain.
        $output = & git -C $Root ls-files -z 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
    }
    if ($exitCode -ne 0) {
        throw "git ls-files failed in '$Root' (exit code $exitCode). The guard needs a git repository, because it only judges tracked files."
    }
    foreach ($file in ((@($output) -join '') -split "`0")) {
        if (-not $file -or $file -match '(^|/)(bin|obj)/') { continue }
        # A file deleted from the working tree but not yet from the index is still listed.
        if (Test-Path -LiteralPath (Join-Path $Root $file) -PathType Leaf) { $file }
    }
}

function Get-ParentFolder {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )
    $index = $RelativePath.LastIndexOf('/')
    if ($index -lt 0) { return '' }
    $RelativePath.Substring(0, $index)
}

function Read-XmlFile {
    <# Loads XML with line information and without DTD processing: pull request content is untrusted. #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try {
        [System.Xml.Linq.XDocument]::Load($reader, [System.Xml.Linq.LoadOptions]::SetLineInfo)
    }
    finally {
        $reader.Dispose()
    }
}

function Get-AttributeValue {
    param(
        [Parameter(Mandatory)]
        [System.Xml.Linq.XElement]$Element,
        [Parameter(Mandatory)]
        [string]$Name
    )
    $attribute = $Element.Attribute([System.Xml.Linq.XName]::Get($Name))
    if ($null -eq $attribute) { return '' }
    $attribute.Value
}

function Get-MetadataValue {
    <# MSBuild metadata can be an attribute or a child element: Version="1.0" or <Version>1.0</Version>. #>
    param(
        [Parameter(Mandatory)]
        [System.Xml.Linq.XElement]$Element,
        [Parameter(Mandatory)]
        [string]$Name
    )
    $value = Get-AttributeValue -Element $Element -Name $Name
    if ($value) { return $value.Trim() }
    foreach ($child in $Element.Elements()) {
        if ($child.Name.LocalName -eq $Name) { return $child.Value.Trim() }
    }
    ''
}

function Get-LineNumber {
    param(
        [Parameter(Mandatory)]
        [System.Xml.Linq.XElement]$Element
    )
    ([System.Xml.IXmlLineInfo]$Element).LineNumber
}

function ConvertTo-NormalizedCondition {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Condition
    )
    if (-not $Condition) { return '' }
    ($Condition -replace '\s+', ' ').Trim()
}

function Get-ElementCondition {
    <# The Condition of the element and of every parent, normalised. Any of them can carry the opt-out. #>
    param(
        [Parameter(Mandatory)]
        [System.Xml.Linq.XElement]$Element
    )
    $node = $Element
    while ($null -ne $node) {
        $condition = ConvertTo-NormalizedCondition (Get-AttributeValue -Element $node -Name 'Condition')
        if ($condition) { $condition }
        $node = $node.Parent
    }
}

#endregion

#region Readers

function Read-MsBuildFile {
    <# Collects direct package references and CPM bypasses from MSBuild files. #>
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$RelativePath
    )
    $references = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $bypasses = [System.Collections.Generic.List[object]]::new()
    $invalid = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $RelativePath) {
        try {
            $document = Read-XmlFile -Path (Join-Path $Root $file)
        }
        catch {
            $invalid.Add($file)
            continue
        }
        foreach ($element in $document.Descendants()) {
            $kind = $element.Name.LocalName
            if ($kind -in 'PackageReference', 'GlobalPackageReference') {
                $include = Get-AttributeValue -Element $element -Name 'Include'
                $target = if ($include) { $include } else { Get-AttributeValue -Element $element -Name 'Update' }
                $packages = @($target.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                # Only Include adds a reference. Update changes metadata of a reference made elsewhere.
                if ($include) { foreach ($package in $packages) { [void]$references.Add($package) } }
                # GlobalPackageReference carries its version by design; that is central, not a bypass.
                if ($kind -ne 'PackageReference') { continue }
                foreach ($metadata in 'Version', 'VersionOverride') {
                    $value = Get-MetadataValue -Element $element -Name $metadata
                    if (-not $value) { continue }
                    $label = if ($metadata -eq 'Version') { 'an inline Version' } else { 'a VersionOverride' }
                    foreach ($package in $packages) {
                        $bypasses.Add([pscustomobject]@{
                                File       = $file
                                Line       = Get-LineNumber -Element $element
                                What       = "PackageReference '$package' sets $label '$value'"
                                Conditions = @(Get-ElementCondition -Element $element)
                            })
                    }
                }
            }
            elseif ($kind -in 'ManagePackageVersionsCentrally', 'ImportDirectoryPackagesProps') {
                # MSBuild compares case-insensitively, and so does -eq.
                if (-not $element.HasElements -and $element.Value.Trim() -eq 'false') {
                    $bypasses.Add([pscustomobject]@{
                            File       = $file
                            Line       = Get-LineNumber -Element $element
                            What       = "$kind is set to false"
                            Conditions = @(Get-ElementCondition -Element $element)
                        })
                }
            }
        }
    }
    [pscustomobject]@{ References = $references; Bypasses = $bypasses; Invalid = $invalid }
}

function Read-CentralPackageVersion {
    <# Returns every PackageVersion entry of the root Directory.Packages.props with its line number. #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    try {
        $document = Read-XmlFile -Path $Path
    }
    catch {
        throw "$script:CentralFileName is not valid XML: $($_.Exception.Message)"
    }
    foreach ($element in $document.Descendants()) {
        if ($element.Name.LocalName -ne 'PackageVersion') { continue }
        $name = (Get-AttributeValue -Element $element -Name 'Include').Trim()
        if (-not $name) { continue }
        [pscustomobject]@{
            Name    = $name
            Version = Get-MetadataValue -Element $element -Name 'Version'
            Line    = Get-LineNumber -Element $element
        }
    }
}

function ConvertTo-GlobRegex {
    <# '*' and '?' stay within one folder, '**' crosses folders, and '**/' also matches no folder at all. #>
    param(
        [Parameter(Mandatory)]
        [string]$Glob
    )
    $text = $Glob.Replace('\', '/').TrimStart('/')
    $pattern = [System.Text.StringBuilder]::new('^')
    $i = 0
    while ($i -lt $text.Length) {
        $character = $text[$i]
        if ($character -eq '*' -and $i + 1 -lt $text.Length -and $text[$i + 1] -eq '*') {
            if ($i + 2 -lt $text.Length -and $text[$i + 2] -eq '/') {
                [void]$pattern.Append('(?:.*/)?')
                $i += 3
            }
            else {
                [void]$pattern.Append('.*')
                $i += 2
            }
            continue
        }
        if ($character -eq '*') { [void]$pattern.Append('[^/]*') }
        elseif ($character -eq '?') { [void]$pattern.Append('[^/]') }
        else { [void]$pattern.Append([regex]::Escape([string]$character)) }
        $i++
    }
    [void]$pattern.Append('$')
    [regex]::new($pattern.ToString(), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Read-Allowlist {
    <# Reads and validates the allowlist. Throws on anything that is not exactly the documented shape. #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$DisplayPath,
        [switch]$Required
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($Required) { throw "Allowlist '$DisplayPath' does not exist." }
        return
    }
    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "Allowlist '$DisplayPath' is not valid JSON: $($_.Exception.Message)"
    }
    if ($json -isnot [System.Collections.IDictionary]) {
        throw "Allowlist '$DisplayPath' must be a JSON object with a 'cpmBypass' array."
    }
    foreach ($key in $json.Keys) {
        if ($key -cne 'cpmBypass' -and -not $key.StartsWith('$')) {
            throw "Allowlist '$DisplayPath' has an unknown property '$key'. Expected 'cpmBypass'."
        }
    }
    if (-not $json.Contains('cpmBypass')) { return }
    $entries = $json['cpmBypass']
    if ($entries -isnot [System.Collections.IList]) {
        throw "Allowlist '$DisplayPath': 'cpmBypass' must be an array."
    }
    $index = 0
    foreach ($entry in $entries) {
        $index++
        $where = "Allowlist '$DisplayPath', entry $index"
        if ($entry -isnot [System.Collections.IDictionary]) { throw "${where}: must be an object." }
        foreach ($key in $entry.Keys) {
            if ($key -cnotin 'path', 'condition', 'reason') {
                throw "${where}: unknown property '$key'. Allowed are 'path', 'condition' and 'reason'."
            }
        }
        $glob = $entry['path']
        if ($glob -isnot [string] -or -not $glob.Trim()) { throw "${where}: 'path' is missing or empty." }
        $reason = $entry['reason']
        if ($reason -isnot [string] -or -not $reason.Trim()) {
            throw "${where} ('$glob'): 'reason' is missing or empty. Every exception must say why it exists."
        }
        $condition = $entry['condition']
        if ($null -ne $condition -and $condition -isnot [string]) { throw "${where} ('$glob'): 'condition' must be a string." }
        [pscustomobject]@{
            Path      = $glob.Trim()
            Regex     = ConvertTo-GlobRegex $glob.Trim()
            Condition = ConvertTo-NormalizedCondition $condition
            Reason    = $reason.Trim()
            Matched   = $false
        }
    }
}

function Test-AllowlistMatch {
    param(
        [Parameter(Mandatory)]
        [object]$Entry,
        [Parameter(Mandatory)]
        [object]$Bypass
    )
    if (-not $Entry.Regex.IsMatch($Bypass.File)) { return $false }
    if (-not $Entry.Condition) { return $true }
    $Bypass.Conditions -contains $Entry.Condition
}

#endregion

#region Analysis

function Get-PinAssessment {
    <#
    .SYNOPSIS
        Walks the valid lock files and assesses every candidate: a PackageVersion without a direct reference.

    .DESCRIPTION
        Per target framework section: which candidates are resolved at all, and whether the central
        version is higher than the highest lower bound a parent package requests. Dependencies listed
        under 'Project' entries are not parent requests: they already carry the central version.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$LockFile,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Candidate
    )
    $assessments = @{}
    foreach ($group in ($Candidate | Group-Object -Property Name)) {
        $pinLower = $null
        $problems = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $group.Group) {
            $lower = Get-LowerBound $entry.Version
            if (-not $lower) {
                $problems.Add("central version '$($entry.Version)' cannot be parsed")
            }
            elseif (-not $pinLower -or (Compare-NuGetVersion -Left $lower -Right $pinLower) -gt 0) {
                $pinLower = $lower
            }
        }
        $assessments[$group.Name] = [pscustomobject]@{
            PinLower = $pinLower
            Sections = 0
            Raised   = $false
            Problems = $problems
            Example  = ''
        }
    }
    $invalid = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $LockFile) {
        try {
            $json = [System.IO.File]::ReadAllText((Join-Path $Root $file)) | ConvertFrom-Json -AsHashtable
        }
        catch {
            $invalid.Add($file)
            continue
        }
        $frameworks = if ($json -is [System.Collections.IDictionary]) { $json['dependencies'] } else { $null }
        if ($frameworks -isnot [System.Collections.IDictionary]) {
            $invalid.Add($file)
            continue
        }
        foreach ($framework in $frameworks.Keys) {
            $section = $frameworks[$framework]
            if ($section -isnot [System.Collections.IDictionary]) { continue }
            $resolved = [System.Collections.Generic.List[string]]::new()
            $requests = @{}
            foreach ($name in $section.Keys) {
                $info = $section[$name]
                if ($info -isnot [System.Collections.IDictionary] -or $info['type'] -eq 'Project') { continue }
                $resolved.Add($name)
                $dependencies = $info['dependencies']
                if ($dependencies -isnot [System.Collections.IDictionary]) { continue }
                foreach ($dependency in $dependencies.Keys) {
                    if (-not $requests.ContainsKey($dependency)) {
                        $requests[$dependency] = [System.Collections.Generic.List[string]]::new()
                    }
                    $requests[$dependency].Add([string]$dependencies[$dependency])
                }
            }
            foreach ($name in $resolved) {
                if (-not $assessments.ContainsKey($name)) { continue }
                $assessment = $assessments[$name]
                $assessment.Sections++
                $where = "$file ($framework)"
                if (-not $assessment.PinLower) { continue }
                if (-not $requests.ContainsKey($name)) {
                    $assessment.Problems.Add("no parent requests it in $where")
                    continue
                }
                $highest = $null
                $comparable = $true
                foreach ($range in $requests[$name]) {
                    $lower = Get-LowerBound $range
                    if (-not $lower) {
                        $assessment.Problems.Add("parent request '$range' in $where cannot be compared")
                        $comparable = $false
                        break
                    }
                    if (-not $highest -or (Compare-NuGetVersion -Left $lower -Right $highest) -gt 0) { $highest = $lower }
                }
                if (-not $comparable) { continue }
                if ((Compare-NuGetVersion -Left $assessment.PinLower -Right $highest) -gt 0) {
                    $assessment.Raised = $true
                }
                elseif (-not $assessment.Example) {
                    $assessment.Example = $where
                }
            }
        }
    }
    [pscustomobject]@{ Assessments = $assessments; Invalid = $invalid }
}

function Get-HygieneReport {
    <# Runs every check and returns the findings plus what -Fix may remove. Reports nothing itself. #>
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [string]$AllowlistFile,
        [switch]$AllowlistRequired
    )
    $centralPath = Join-Path $Root $script:CentralFileName
    if (-not (Test-Path -LiteralPath $centralPath -PathType Leaf)) {
        throw "No $script:CentralFileName found in '$Root'. The guard checks repositories that use Central Package Management."
    }
    $allowlistDisplay = [System.IO.Path]::GetRelativePath($Root, $AllowlistFile).Replace('\', '/')
    if ($allowlistDisplay.StartsWith('..')) { $allowlistDisplay = $AllowlistFile }
    $allowlist = @(Read-Allowlist -Path $AllowlistFile -DisplayPath $allowlistDisplay -Required:$AllowlistRequired)

    $tracked = @(Get-TrackedFile -Root $Root)
    $projectFiles = @($tracked | Where-Object { $_ -match '\.[A-Za-z0-9]+proj$' })
    $msbuildFiles = @($tracked | Where-Object { $_ -match '\.([A-Za-z0-9]+proj|props|targets)$' })
    $lockFiles = @($tracked | Where-Object { $_ -match '(^|/)packages\.lock\.json$' })

    $projectFolders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($project in $projectFiles) { [void]$projectFolders.Add((Get-ParentFolder $project)) }
    $orphanedLockFiles = @($lockFiles | Where-Object { -not $projectFolders.Contains((Get-ParentFolder $_)) })
    # An orphaned lock file is never evidence that an entry is alive.
    $validLockFiles = @($lockFiles | Where-Object { $projectFolders.Contains((Get-ParentFolder $_)) })

    $msbuild = Read-MsBuildFile -Root $Root -RelativePath $msbuildFiles
    $entries = @(Read-CentralPackageVersion -Path $centralPath)
    $candidates = @($entries | Where-Object { -not $msbuild.References.Contains($_.Name) })
    $pins = Get-PinAssessment -Root $Root -LockFile $validLockFiles -Candidate $candidates

    $findings = [System.Collections.Generic.List[object]]::new()
    $deadNames = [System.Collections.Generic.List[string]]::new()

    foreach ($group in ($candidates | Group-Object -Property Name)) {
        $first = $group.Group[0]
        $assessment = $pins.Assessments[$group.Name]
        $label = "PackageVersion '$($first.Name)' ($($first.Version))"
        if ($assessment.Sections -eq 0) {
            $deadNames.Add($first.Name)
            $findings.Add((New-Finding -Severity error -Rule 'dead-entry' -Path $script:CentralFileName -Line $first.Line -Message (
                        "$label is not referenced directly by any tracked project or props file and no valid lock file resolves it. Remove the entry; locally -Fix does that.")))
        }
        elseif ($assessment.Raised) {
            continue
        }
        elseif ($assessment.Problems.Count -gt 0) {
            $findings.Add((New-Finding -Severity warning -Rule 'pin-not-comparable' -Path $script:CentralFileName -Line $first.Line -Message (
                        "$label cannot be assessed ($($assessment.Problems[0])). The pin is treated as effective.")))
        }
        else {
            $findings.Add((New-Finding -Severity warning -Rule 'pin-without-effect' -Path $script:CentralFileName -Line $first.Line -Message (
                        "$label has no direct reference and is not higher than the highest version a parent requests in any of its $($assessment.Sections) lock file section(s), for example $($assessment.Example). NuGet resolves that version anyway: remove the entry and regenerate the lock files.")))
        }
    }

    foreach ($file in $orphanedLockFiles) {
        $findings.Add((New-Finding -Severity error -Rule 'orphaned-lock-file' -Path $file -Message (
                    "$file has no project file in the same folder. Delete it; locally -Fix does that.")))
    }

    foreach ($file in $pins.Invalid) {
        $findings.Add((New-Finding -Severity error -Rule 'invalid-lock-file' -Path $file -Message (
                    "$file is not a NuGet lock file (JSON with a 'dependencies' object). Regenerate it with 'dotnet restore --force-evaluate'.")))
    }

    foreach ($file in $msbuild.Invalid) {
        $findings.Add((New-Finding -Severity warning -Rule 'invalid-msbuild' -Path $file -Message (
                    "$file is not valid XML and was skipped.")))
    }

    foreach ($bypass in $msbuild.Bypasses) {
        $covering = @($allowlist | Where-Object { Test-AllowlistMatch -Entry $_ -Bypass $bypass })
        if ($covering.Count -gt 0) {
            foreach ($entry in $covering) { $entry.Matched = $true }
            continue
        }
        $conditionText = if ($bypass.Conditions.Count -gt 0) { " under condition $($bypass.Conditions -join ' and ')" } else { '' }
        $findings.Add((New-Finding -Severity error -Rule 'cpm-bypass' -Path $bypass.File -Line $bypass.Line -Message (
                    "$($bypass.What)$conditionText. Use the central PackageVersion in $script:CentralFileName, or record an exception with a reason in $allowlistDisplay.")))
    }

    foreach ($entry in $allowlist) {
        if ($entry.Matched) { continue }
        $findings.Add((New-Finding -Severity warning -Rule 'stale-allowlist' -Path $allowlistDisplay -Message (
                    "Allowlist entry '$($entry.Path)' no longer matches any CPM bypass. Remove it from $allowlistDisplay.")))
    }

    [pscustomobject]@{
        Findings          = $findings
        DeadNames         = $deadNames
        OrphanedLockFiles = $orphanedLockFiles
        Statistics        = "$($entries.Count) PackageVersion entries, $($projectFiles.Count) project files, $($validLockFiles.Count) lock files ($($orphanedLockFiles.Count) orphaned), $($allowlist.Count) allowlist entries."
    }
}

#endregion

#region Fix

function Remove-DeadPackageVersion {
    <# Removes the entries as text, so formatting, comments, line endings and a byte order mark survive. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string[]]$Name
    )
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $content = [System.IO.File]::ReadAllText($Path)
    $changed = $false
    $options = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Multiline, Singleline'
    foreach ($package in $Name) {
        if (-not $PSCmdlet.ShouldProcess("$script:CentralFileName", "Remove dead PackageVersion '$package'")) { continue }
        $start = '^[ \t]*<PackageVersion\b[^>]*?\bInclude\s*=\s*["'']' + [regex]::Escape($package) + '["'']'
        $selfClosing = $start + '[^>]*/>[ \t]*(?:\r?\n)?'
        $withChildren = $start + '[^>]*(?<!/)>.*?</PackageVersion\s*>[ \t]*(?:\r?\n)?'
        $updated = [regex]::Replace($content, $selfClosing, '', $options)
        $updated = [regex]::Replace($updated, $withChildren, '', $options)
        if ($updated -eq $content) {
            Write-Warning "Could not locate PackageVersion '$package' in $script:CentralFileName as text; remove it by hand."
            continue
        }
        $content = $updated
        $changed = $true
        Write-Output "Removed PackageVersion '$package' from $script:CentralFileName"
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($hasBom))
    }
}

function Remove-OrphanedLockFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [Parameter(Mandatory)]
        [string[]]$RelativePath
    )
    foreach ($file in $RelativePath) {
        if (-not $PSCmdlet.ShouldProcess($file, 'Delete orphaned lock file')) { continue }
        Remove-Item -LiteralPath (Join-Path $Root $file) -Confirm:$false
        Write-Output "Deleted orphaned lock file $file"
    }
}

#endregion

try {
    $root = [System.IO.Path]::TrimEndingDirectorySeparator(
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepositoryRoot))
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Repository root '$RepositoryRoot' does not exist."
    }
    # Resolve through PowerShell, not [IO.Path]::GetFullPath: the process directory can differ from
    # the current location, and PowerShell drives such as TestDrive: mean nothing to .NET.
    $allowlistFile = if ($AllowlistPath) {
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($AllowlistPath)
    }
    else {
        Join-Path $root $script:DefaultAllowlistPath
    }
    $reportParameters = @{
        Root              = $root
        AllowlistFile     = $allowlistFile
        AllowlistRequired = [bool]$AllowlistPath
    }

    $report = Get-HygieneReport @reportParameters

    if ($Fix) {
        if ($report.DeadNames.Count -gt 0) {
            Remove-DeadPackageVersion -Path (Join-Path $root $script:CentralFileName) -Name $report.DeadNames
        }
        if ($report.OrphanedLockFiles.Count -gt 0) {
            Remove-OrphanedLockFile -Root $root -RelativePath $report.OrphanedLockFiles
        }
        $report = Get-HygieneReport @reportParameters
    }

    Write-Output "Package guard: $($report.Statistics)"
    $sorted = $report.Findings | Sort-Object -Property @{ Expression = { $_.Severity -ne 'error' } }, Path, Line
    foreach ($finding in $sorted) { Write-Finding -Finding $finding }
    $errorCount = @($report.Findings | Where-Object Severity -EQ 'error').Count
    $warningCount = @($report.Findings | Where-Object Severity -EQ 'warning').Count
    Write-Output "Package guard: $errorCount error(s), $warningCount warning(s)."
    if ($errorCount -gt 0) { exit 1 }
    exit 0
}
catch {
    Write-Finding -Finding (New-Finding -Severity error -Rule 'guard' -Message $_.Exception.Message)
    exit 1
}
