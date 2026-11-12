<#
.SYNOPSIS
    Verifies that every relative link and anchor in the Markdown files resolves.

.DESCRIPTION
    Two failure modes this catches, both of which are easy to introduce by hand and invisible until
    a reader clicks:

      - a relative link to a file that does not exist
      - an anchor pointing at a heading that does not exist, in this or another file

    External http(s) links are not checked; that needs network access and produces flaky builds.

.PARAMETER Path
    Root to scan. Defaults to the repository root.

.EXAMPLE
    pwsh ./tools/Test-DocumentationLinks.ps1
#>
[CmdletBinding()]
param(
    [string] $Path = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HeadingAnchor {
    <# GitHub's slug rules: lowercase, drop punctuation, spaces to hyphens. #>
    param([string] $File)
    Get-Content -LiteralPath $File |
        Where-Object { $_ -match '^#{1,6}\s+' } |
        ForEach-Object { (($_ -replace '^#{1,6}\s+', '').ToLower() -replace '[^\w\s-]', '') -replace '\s+', '-' }
}

$files = Get-ChildItem -Path $Path -Recurse -File -Filter '*.md' |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.FullName -notmatch '[\\/]node_modules[\\/]' }

Write-Host "Checking $($files.Count) Markdown files under $Path"

$findings = @()
foreach ($file in $files) {
    $dir = $file.DirectoryName
    $source = [IO.Path]::GetRelativePath($Path, $file.FullName)
    $content = Get-Content -LiteralPath $file.FullName -Raw

    foreach ($match in [regex]::Matches($content, '\]\((?<target>[^)\s]*?)(?:#(?<anchor>[^)\s]+))?\)')) {
        $target = $match.Groups['target'].Value
        $anchor = $match.Groups['anchor'].Value

        if ($target -match '^(https?|mailto):') { continue }
        if (-not $target -and -not $anchor) { continue }

        $resolved = if ($target) { Join-Path $dir $target } else { $file.FullName }

        if (-not (Test-Path -LiteralPath $resolved)) {
            $findings += "missing file   $source -> $target"
            continue
        }
        if ($anchor -and $resolved -like '*.md') {
            if ((Get-HeadingAnchor $resolved) -notcontains $anchor.ToLower()) {
                $findings += "missing anchor $source -> $target#$anchor"
            }
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Host 'All relative links and anchors resolve.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host "$($findings.Count) broken link(s):" -ForegroundColor Red
$findings | ForEach-Object { Write-Host "  $_" }
exit 1
