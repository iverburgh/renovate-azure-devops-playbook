# Central package hygiene

Renovate keeps every version in `Directory.Packages.props` current. It does not ask whether the
entry is still used, whether a project bypasses it, or whether the pin still does anything. A
package guard asks those questions on every pull request that touches package files.

This page describes `scripts/Test-PackageHygiene.ps1`, the allowlist in
`config/package-hygiene-allowlist.json` and the build validation in `pipelines/package-guard.yml`.
It assumes NuGet [Central Package Management](https://learn.microsoft.com/nuget/consume-packages/central-package-management)
(CPM) with one `Directory.Packages.props` at the repository root.

## Why a package guard

Central Package Management puts every version in one file. That file only grows on its own:

| Problem | How it happens | What it costs |
|---|---|---|
| Dead entries | A project drops a package, nobody removes the `PackageVersion` | Renovate keeps updating it. The NuGet group pull request carries versions, release notes and sometimes breaking changes for a package nothing uses |
| Orphaned lock files | A project is moved or deleted, its `packages.lock.json` stays | Nothing restores it, so nothing updates it. Tools that read lock files, such as dependency scanners, keep reporting the old versions |
| CPM bypasses | An inline `Version`, a `VersionOverride`, or CPM switched off for a folder | A second source of truth. It drifts from the central version, it is easy to miss in review, and an `ignorePaths` entry takes it out of updates entirely |
| Pins without effect | A transitive package was pinned to lift a vulnerable version; later its parent asks for that version itself | The entry pretends to matter. Readers take it for a security floor, and Renovate still proposes updates for it |

None of these breaks a build. That is why they pile up.

## What it checks

| Rule | Severity | Meaning |
|---|---|---|
| `dead-entry` | error | A `PackageVersion` that no project or props file references and no lock file resolves |
| `orphaned-lock-file` | error | A `packages.lock.json` without a project file in the same folder |
| `cpm-bypass` | error | `ManagePackageVersionsCentrally` or `ImportDirectoryPackagesProps` set to `false`, or a `PackageReference` with `Version` or `VersionOverride`, not covered by the allowlist |
| `invalid-lock-file` | error | A lock file that is not JSON with a `dependencies` object |
| `pin-without-effect` | warning | A transitive pin that is not higher than what a parent already requests |
| `pin-not-comparable` | warning | The same check, but a version or range could not be compared. Treated as effective |
| `stale-allowlist` | warning | An allowlist entry that no longer matches any bypass |
| `invalid-msbuild` | warning | An MSBuild file that is not valid XML. It is skipped |

Errors fail the run. Warnings never do.

The guard only reads files that git tracks and that exist on disk, and it ignores everything below
`bin/` and `obj/`. It judges what a clean checkout contains, which is what the pipeline and
Renovate see. A new project counts once it is staged with `git add`.

## The rules

### Dead entries

```xml
<!-- Directory.Packages.props -->
<PackageVersion Include="Serilog" Version="3.1.1" />
<PackageVersion Include="Polly" Version="8.4.1" />   <!-- no project references Polly -->
```

```text
ERROR: Directory.Packages.props:3: [dead-entry] PackageVersion 'Polly' (8.4.1) is not referenced directly by any tracked project or props file and no valid lock file resolves it. ...
```

An entry is alive when either of these holds:

- a tracked project, `.props` or `.targets` file has `<PackageReference Include="...">` or
  `<GlobalPackageReference Include="...">` for it. Semicolon-separated lists count.
- a lock file next to a project resolves it, so it is a transitive pin.

`<PackageReference Update="...">` does not count. It changes metadata of a reference made
elsewhere; if there is no such reference, it changes nothing.

**Fix:** delete the entry. `-Fix` does that for you. Conditional duplicates of one package (one
entry per target framework) are reported once and removed together.

Transitive pins are only visible through lock files. Without `RestorePackagesWithLockFile` every
transitive pin looks dead. Turn lock files on before you turn the guard on.

### Orphaned lock files

```text
src/Old.Service/packages.lock.json      <- the project file is gone
```

```text
ERROR: src/Old.Service/packages.lock.json: [orphaned-lock-file] src/Old.Service/packages.lock.json has no project file in the same folder. ...
```

Any `*.<something>proj` file counts as the project, so a `.sqlproj` with a lock file is fine. An
orphaned lock file is never evidence that an entry is alive: a dead entry stays dead even if an
old lock file still mentions it.

**Fix:** delete the file. `-Fix` does that for you.

A lock file that is not JSON, or has no `dependencies` object, is reported as `invalid-lock-file`.
Regenerate it with `dotnet restore --force-evaluate`.

### CPM bypasses

All of these are bypasses:

```xml
<!-- CPM switched off for everything that imports this file -->
<ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally>
<ImportDirectoryPackagesProps>false</ImportDirectoryPackagesProps>

<!-- a version decided in the project, not centrally -->
<PackageReference Include="Serilog" Version="3.0.0" />
<PackageReference Include="Serilog" VersionOverride="3.0.0" />
<PackageReference Update="Serilog">
  <Version>3.0.0</Version>
</PackageReference>
```

```text
ERROR: src/Orders.Api/Orders.Api.csproj:12: [cpm-bypass] PackageReference 'Serilog' sets a VersionOverride '3.0.0'. ...
```

Some of these NuGet already rejects. An inline `Version` under CPM fails restore with `NU1008`, and
`CentralPackageVersionOverrideEnabled=false` turns every `VersionOverride` into an error. The guard
still earns its place: it reports before a build runs, it catches the folders where CPM is switched
off and those errors never fire, and it keeps the deliberate exceptions in one reviewed list.

`GlobalPackageReference` carries a version by design. It lives in `Directory.Packages.props` and is
not a bypass.

**Fix:** remove the version from the project so the central `PackageVersion` applies. If the
bypass is deliberate, add it to the allowlist with a reason.

### Pins without effect

This rule assumes `CentralPackageTransitivePinningEnabled`. With it, a `PackageVersion` for a
package you do not reference directly raises that transitive package to the central version.
Without it, such an entry does nothing at all, whatever its version.

A pin only does something when it is higher than what the parents already ask for:

```jsonc
// packages.lock.json (net8.0)
"Orders.Client": { "type": "Transitive", "dependencies": { "Newtonsoft.Json": "13.0.3" } },
"Newtonsoft.Json": { "type": "CentralTransitive", "requested": "[13.0.3, )", "resolved": "13.0.3" }
```

The parent asks for 13.0.3 and the pin says 13.0.3. NuGet resolves 13.0.3 with or without the pin.

```text
WARNING: Directory.Packages.props:8: [pin-without-effect] PackageVersion 'Newtonsoft.Json' (13.0.3) has no direct reference and is not higher than the highest version a parent requests ...
```

How the comparison works:

- It runs per target framework section of every lock file. The pin counts as effective when it
  raises the version in at least one section.
- Of all parents, the highest request counts. Dependencies listed under `Project` entries are
  ignored, because they already carry the central version.
- Versions compare like NuGet: missing parts are zero (`3.1` equals `3.1.0.0`), a release is higher
  than its prereleases, numeric labels compare as numbers (`rc.10` above `rc.9`), labels compare
  case-insensitively, and `+metadata` is ignored.
- A floating version, an exclusive lower bound such as `(13.0.1, )`, a version from a property
  such as `$(JsonVersion)` or a section without a parent request cannot be compared. That gives
  `pin-not-comparable` and the pin is treated as effective.

**Fix:** remove the entry and regenerate the lock files with `dotnet restore --force-evaluate`. It is
a warning and `-Fix` leaves it alone, because the lock files change with it.

Document why a transitive pin exists when you add it, so the warning tells you something:

```xml
<!-- Via: Orders.Client. Reason: lifts a vulnerable version; remove when Orders.Client requires 13.0.3. -->
<PackageVersion Include="Newtonsoft.Json" Version="13.0.3" />
```

## The allowlist

Deliberate bypasses go in `config/package-hygiene-allowlist.json`:

```json
{
  "$comment": "Free text. Top-level properties starting with $ are ignored.",
  "cpmBypass": [
    {
      "path": "src/Functions/Directory.Build.props",
      "condition": "'$(MSBuildProjectName)' == 'WorkerExtensions'",
      "reason": "The Functions worker SDK generates this project and restores it with its own versions."
    },
    {
      "path": "tools/legacy/**",
      "reason": "Non-SDK tooling that cannot import Directory.Packages.props. Remove after the migration."
    }
  ]
}
```

| Property | Required | Meaning |
|---|---|---|
| `path` | yes | Glob on the repository-relative path. `*` and `?` stay within one folder, `**` crosses folders, and `**/` also matches no folder at all. Case-insensitive |
| `condition` | no | The bypass must sit under exactly this MSBuild `Condition`, on the element itself or on any parent. Whitespace is normalised, case is ignored. Without it, every bypass in the file is covered |
| `reason` | yes | Why the exception exists, and when it can go |

The file is validated strictly. Invalid JSON, an unknown property, or a missing `path` or `reason`
stops the run with an error before anything else is checked. A typo in a property name would
otherwise silently widen or narrow an exception.

An entry that matches no bypass any more gives a `stale-allowlist` warning. Remove it, or it will
quietly cover the next bypass that happens to land in that path.

### Why the reason is mandatory

An exception without a reason is permanent. Nobody dares to remove it, because nobody knows what
breaks. A reason turns it into a decision someone can revisit: it names the constraint and, ideally,
what lifts it. This is the same rule as for Renovate pins, where every `allowedVersions` needs a
`description` with its exit — see [pitfalls](pitfalls.md#a-pin-that-excludes-the-current-version-is-permanent-not-temporary).

The default allowlist path is `config/package-hygiene-allowlist.json` below the repository root.
When that file does not exist the allowlist is empty. A path passed with `-AllowlistPath` must
exist, so a typo cannot switch every exception off.

## Running it locally

PowerShell 7.2 or newer and git. From the repository root:

```powershell
./scripts/Test-PackageHygiene.ps1 -RepositoryRoot .
```

```text
Package guard: 112 PackageVersion entries, 58 project files, 54 lock files (1 orphaned), 2 allowlist entries.
ERROR: Directory.Packages.props:41: [dead-entry] PackageVersion 'Polly' (8.4.1) is not referenced ...
ERROR: src/Old.Service/packages.lock.json: [orphaned-lock-file] ...
WARNING: Directory.Packages.props:77: [pin-without-effect] PackageVersion 'Newtonsoft.Json' (13.0.3) ...
Package guard: 2 error(s), 1 warning(s).
```

| Exit code | Meaning |
|---|---|
| `0` | No errors. Warnings are allowed |
| `1` | At least one error, or the guard could not run: no git repository, no `Directory.Packages.props`, an invalid allowlist |

## Fixing with -Fix

```powershell
./scripts/Test-PackageHygiene.ps1 -RepositoryRoot . -Fix -WhatIf   # show what would change
./scripts/Test-PackageHygiene.ps1 -RepositoryRoot . -Fix           # do it
```

`-Fix` removes dead `PackageVersion` entries and deletes orphaned lock files, then checks again and
reports what is left. It does nothing else:

- Entries are removed as text, so formatting, line endings and a byte order mark survive. A comment
  above a removed entry stays; delete it by hand.
- Pins without effect, bypasses and stale allowlist entries need a decision, so they stay.
- A second run changes nothing.
- `-WhatIf` and `-Confirm` work as usual.

`-Fix` cannot be combined with `-Ci`. The pipeline reports; a developer fixes and commits.

## Running it in the pipeline

`pipelines/package-guard.yml` runs the guard with `-Ci`. Findings become Azure DevOps logging
commands, so they show as annotations on the run and on the pull request, with file and line.

Like the [config check](getting-started.md#5-attach-the-config-check-pipeline-as-a-branch-policy),
it has `trigger: none` and `pr: none` and does nothing until you attach it as a build validation
policy on your default branch. Give the policy a path filter so it only runs when package files
change:

```text
/Directory.Packages.props;*.csproj;*.props;*.targets;*/packages.lock.json;/scripts/Test-PackageHygiene.ps1;/config/package-hygiene-allowlist.json
```

In a policy path filter `*` also crosses folders, so `*.csproj` covers every project. Add
`*.fsproj`, `*.vbproj` or `*.sqlproj` if you have them. The script and the allowlist are in the
filter because a change to either changes the outcome.

Make the policy required. An optional guard is a guard that gets ignored on the one pull request
that needed it.

## Next to Renovate pull requests

Renovate and the guard divide the work. Renovate moves versions; the guard keeps the list of
versions honest.

- **The NuGet group pull request gets smaller and more honest.** Under CPM every NuGet update lands
  in [one pull request](pitfalls.md#central-package-management-forces-every-nuget-update-into-a-single-pull-request).
  Every dead entry adds to it; with the guard there are none.
- **Renovate pull requests run the guard too.** They change `Directory.Packages.props` and lock
  files, so the path filter catches them. They normally pass: Renovate changes versions, not which
  packages exist. If one fails, the problem was already on the default branch, so fix it there.
- **Cleanup happens where the cause is.** A feature pull request that drops the last reference to
  a package fails until it also drops the central entry. Without the guard that cleanup never
  happens, and Renovate updates the leftover forever.
- **Transitive pins get an end.** When a parent package catches up, `pin-without-effect` tells you
  the pin can go. That is often the result of a Renovate update to the parent.
- **Two kinds of pin, two places.** An `allowedVersions` pin in `renovate.json` stops Renovate
  proposing a version. A transitive `PackageVersion` raises a version NuGet would otherwise pick.
  The guard only looks at the second kind. One can force the other — see
  [pitfalls](pitfalls.md#a-pin-can-force-a-second-pin).

## Limits

- **It reads files; it does not evaluate MSBuild.** A property set through another property, an
  import from outside the repository or a package name taken from a variable is invisible to it.
  The text `false` inside another property's value is not an opt-out.
- **Only the root `Directory.Packages.props` is analysed.** References from every tracked project
  and props file count, but a nested `Directory.Packages.props` has its own entries that the guard
  does not check.
- **Transitive pins need lock files.** See [dead entries](#dead-entries).
- **Only tracked files count.** Untracked projects and lock files are ignored, on purpose.
