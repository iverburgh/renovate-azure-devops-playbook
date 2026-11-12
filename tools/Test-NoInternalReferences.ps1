<#
.SYNOPSIS
    Fails if any organisation-specific reference leaks into this repository.

.DESCRIPTION
    This playbook was extracted from a private repository. Everything published here must be
    generic: no organisation names, no internal hostnames, no work item numbers, no build numbers,
    and above all no callable endpoints such as signed webhook URLs.

    Run this before every push. It exits 1 when anything matches, so it can be wired into a
    pre-commit hook or a CI step.

    Generic patterns are built in. The names of the organisation and product this playbook was
    extracted from are deliberately NOT in this file - listing them would publish them. They are
    loaded from:

      - tools/forbidden-terms.local.txt  (git-ignored; one regular expression per line, # comments)
      - the FORBIDDEN_TERMS environment variable (separated by newlines or semicolons), which CI
        fills from a repository secret

    Matches on those terms are reported by file and line only; the matched text is never printed,
    because CI logs of a public repository are public too.

.PARAMETER Path
    Root to scan. Defaults to the repository root (the parent of this script's folder).

.EXAMPLE
    pwsh ./tools/Test-NoInternalReferences.ps1
#>
[CmdletBinding()]
param(
    [string] $Path = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Each entry is a named pattern plus why it must never appear. Add your own before publishing:
# the point of this list is that it grows as you discover what you nearly leaked.
$forbidden = @(
    @{ Name = 'Signed webhook URL';    Pattern = 'sig=[A-Za-z0-9_\-%]{20,}'; Why = 'A callable endpoint with its signature is a credential.' }
    @{ Name = 'Power Platform host';   Pattern = 'powerplatform\.com|logic\.azure\.com';                Why = 'Flow endpoints are tenant specific.' }
    @{ Name = 'Organisation URL';      Pattern = 'dev\.azure\.com/(?!<)[A-Za-z0-9._-]+/[A-Za-z0-9._-]'; Why = 'Use dev.azure.com/<org>/<project> instead.' }
    @{ Name = 'Private feed';          Pattern = 'pkgs\.dev\.azure\.com/(?!<)[A-Za-z0-9._-]+/_packaging'; Why = 'Use <org> and <feed> placeholders.' }
    @{ Name = 'Internal mail domain';  Pattern = '@(?!example\.com)[A-Za-z0-9-]+\.(nl|local|internal)\b'; Why = 'Use example.com.' }
    @{ Name = 'Named agent pool';      Pattern = 'buildagents-[a-z0-9-]+';                              Why = 'Use <your-pool> or a hosted image.' }
    @{ Name = 'Work item reference';   Pattern = '(?i)\b(PBI|task|feature)\s*#?\s*\d{5,}\b|#\d{6,}';     Why = 'Internal tracking numbers.' }
    @{ Name = 'Build number';          Pattern = '(?i)\bbuild\s+1\d{6}\b';                              Why = 'Internal tracking numbers.' }
    @{ Name = 'Sprint reference';      Pattern = '(?i)\bsprint\s+\d+\b';                                Why = 'Internal planning.' }
    @{ Name = 'Identity GUID';         Pattern = 'Build\\\\[0-9a-f]{8}-[0-9a-f]{4}';                    Why = 'Service identity of a real organisation.' }
    @{ Name = 'Windows user path';     Pattern = '(?i)C:\\Users\\(?!<)[A-Za-z0-9._-]+\\';               Why = 'Personal paths identify people.' }
    @{ Name = 'Dutch text';            Pattern = '(?i)\b(werd|wordt|niet|geen|deze|zodat|omdat|waardoor|bijvoorbeeld|voorkomt)\b'; Why = 'Repository is English-only.' }
)

$localTerms = Join-Path $PSScriptRoot 'forbidden-terms.local.txt'
$extra = @()
if (Test-Path $localTerms) { $extra += Get-Content $localTerms }
if ($env:FORBIDDEN_TERMS) { $extra += $env:FORBIDDEN_TERMS -split '[;\r\n]+' }
$extra = @($extra | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })

# Scan everything except binaries. An allow-list of extensions would silently skip dotfiles such as
# .gitignore and .nvmrc, which is exactly where a stray reference hides.
$binary = '\.(png|jpe?g|gif|ico|svg|pdf|zip|gz|7z|dll|exe|pfx|snk|woff2?|ttf)$'

$files = Get-ChildItem -Path $Path -Recurse -File -Force |
    Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and
        $_.FullName -notmatch '[\\/]node_modules[\\/]' -and
        $_.Extension -notmatch $binary -and
        $_.FullName -ne $PSCommandPath -and
        $_.FullName -ne $localTerms
    }

Write-Host "Scanning $(@($files).Count) files under $Path"
if ($extra.Count -eq 0) {
    Write-Warning 'No organisation-specific terms loaded: create tools/forbidden-terms.local.txt or set FORBIDDEN_TERMS. Only generic patterns are checked.'
}
else {
    Write-Host "Loaded $($extra.Count) organisation-specific term(s)."
}

$findings = @()
foreach ($rule in $forbidden) {
    foreach ($file in $files) {
        $hits = Select-String -Path $file.FullName -Pattern $rule.Pattern -AllMatches -ErrorAction SilentlyContinue
        foreach ($hit in $hits) {
            $findings += [pscustomobject]@{
                Rule = $rule.Name
                File = [IO.Path]::GetRelativePath($Path, $hit.Path)
                Line = $hit.LineNumber
                Text = $hit.Line.Trim()
                Why  = $rule.Why
            }
        }
    }
}

if ($extra.Count -gt 0) {
    $termPatterns = @($extra | ForEach-Object { [regex]::new("(?i)$_") })
    foreach ($file in $files) {
        $lineNumber = 0
        foreach ($line in [IO.File]::ReadLines($file.FullName)) {
            $lineNumber++
            if (@($termPatterns | Where-Object { $_.IsMatch($line) }).Count -gt 0) {
                $findings += [pscustomobject]@{
                    Rule = 'Organisation-specific term'
                    File = [IO.Path]::GetRelativePath($Path, $file.FullName)
                    Line = $lineNumber
                    # CI logs are public: never echo an organisation-specific match.
                    Text = '(match hidden)'
                    Why  = 'Listed in forbidden-terms.local.txt or FORBIDDEN_TERMS.'
                }
            }
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Host 'No internal references found.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host "$($findings.Count) potential leak(s) found:" -ForegroundColor Red
foreach ($group in $findings | Group-Object Rule) {
    Write-Host ''
    Write-Host "  $($group.Name) - $($group.Group[0].Why)" -ForegroundColor Yellow
    foreach ($f in $group.Group) {
        $snippet = if ($f.Text.Length -gt 110) { $f.Text.Substring(0, 110) + '...' } else { $f.Text }
        Write-Host "    $($f.File):$($f.Line)  $snippet"
    }
}
Write-Host ''
exit 1
