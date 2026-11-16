# Pitfalls

Everything here bit us in production. Each entry is written as symptom first, because that is how
you will meet it: something looks fine and quietly is not.

Roughly half of these are Azure DevOps specific. Renovate's documentation is written
platform-agnostically and does not always call out where Azure behaves differently.

---

## Configuration and grouping

### Central Package Management forces every NuGet update into a single pull request

**Symptom.** Pull requests arrive without `packages.lock.json` and carry an "Artifact update
problem" comment. The log shows `NU1109` downgrade conflicts.

**Cause.** With `Directory.Packages.props` and `CentralPackageTransitivePinningEnabled`, .NET
packages carry tightly coupled transitive requirements. Split the updates across pull requests and
you split apart bumps that must land together. A patch-level pull request bumps a package that
transitively requires a minor-level bump sitting in a *different* pull request, and the restore
fails. It breaks in both directions.

We proved this three times before accepting it: first splitting major/minor/patch, then
minor+patch together with majors separate, and only `separateMajorMinor: false` plus
`separateMinorPatch: false` plus a single `nuget` group produced a mergeable pull request with all
lock files regenerated.

**Fix.** One group for all of NuGet. The trade-off is real and deliberate: one broken major blocks
the whole batch. Mitigate that with a targeted `allowedVersions` pin rather than by splitting.

### `enabledManagers: []` enables every manager

An empty array does not mean "none". Renovate treats it as unset and runs everything. To disable a
manager, leave it out of the list or use `"enabled": false` in a package rule.

This is worth a fail-fast guard anywhere you build the list dynamically — see the managers override
in [pipelines/renovate.yml](../pipelines/renovate.yml).

### Presets copied from older examples fail the strict validator

**Symptom.** `renovate-config-validator --strict` exits with `1` and prints a "Config migration
diff", or warns that an option "can only be used in `customManagers`".

**Cause.** Several option names in older blog posts and shared presets have been renamed:
`managers` became `matchManagers`, `matchPackagePatterns` became `matchPackageNames` with a
`/regex/` value, and `matchFiles` became `matchFileNames`. Renovate migrates them silently at run
time, but `--strict` treats a needed migration as a failure. A regex manager (`matchStrings`,
`datasourceTemplate`, `depNameTemplate`) put inside `packageRules` is simply invalid; it belongs in
`customManagers`.

**Fix.** Apply the migration diff the validator prints. And check whether you need the custom
manager at all: the native `nuget` manager already reads the .NET SDK version from `global.json`.

### The bicep manager updates API versions, not modules

The manager supports exactly one datasource, `azure-bicep-resource`, which updates the Azure REST
API version in resource declarations. It never updates module references. If your modules are local
paths, Renovate has nothing to do with them and you will get zero pull requests while assuming the
feature works.

### Bicep bumps crawl forward instead of jumping to the latest

**Symptom.** `2020-06-01` becomes `2020-11-01` while the provider is already on `2025-09-01`, and
the same resource type shows up as several separate dependencies.

**Cause.** `maxMajorIncrement` defaults to 500. Azure REST API versions are dates treated as
numbers, so 500 is about five months per step.

**Fix.** `"maxMajorIncrement": 0` on the bicep rule. Bumps then converge on the latest stable
version, and resource types that appear with different source versions all land on one target.

### Do not split Bicep per resource provider

It looks like isolation and is the opposite. Shared Bicep modules are referenced by nearly every
pipeline, so a per-provider split multiplies the build fan-out instead of containing it. In our
repository that was the difference between roughly 47 and roughly 705 validation builds from a
single Renovate run, which exhausted the agent pool.

### The native azure-pipelines manager silently skips files

**Symptom.** Far fewer task references found than exist, with no warning.

**Cause.** Two layers. First, the default file patterns only match `.azuredevops/*.yml` and
`azure-pipelines*.yml`, so a repository using other names gets zero detections. Second, and worse:
Renovate parses pipeline YAML statically, and any file containing `${{ if }}` or `${{ each }}` fails
schema validation and is skipped *entirely*. In our measurement that was 38% of all files, with 100%
correlation to the presence of template expressions.

**Fix.** Use a custom regex manager instead, as in [config/renovate.json](../config/renovate.json).
Add `extractVersion` too, or you will get proposals like `CopyFiles@2.279.0`, which is not a valid
task reference.

### Group on the datasource, not the manager

Every custom regex manager reports as `regex` in the statistics. `matchManagers: ["regex"]` will
therefore sweep in unrelated custom managers. Use `matchDatasources` instead.

### The node datasource returns versions with a `v` prefix

**Symptom.** No Node updates, ever. No error, no warning, and "no updates" looks perfectly normal
for months.

**Cause.** `node-version` returns `v24.21.0`. A pin of `/^24\./` filters everything away.

**Fix.** `/^v?24\./`. This is the archetype of the whole category: a pin that matches nothing fails
silently.

### A top-level `minimumReleaseAge` silently stops task and Bicep updates

**Symptom.** After introducing a cooldown, the Azure DevOps task group and the Bicep group stop
appearing. No error. The debug log says
`Marking N release(s) as pending, as they do not have a releaseTimestamp`.

**Cause.** The `azure-pipelines-tasks` and `azure-bicep-resource` datasources publish no release
timestamp. Under the default `minimumReleaseAgeBehaviour` of `timestamp-required`, an update without
one never becomes old enough.

**Fix.** Set `minimumReleaseAge` in a package rule on `matchDatasources: ["npm", "nuget"]` only, and
exempt trusted internal packages with `null` in a rule *after* it. See
[configuration](configuration.md#cooldown-a-minimum-release-age).

---

## Pins

### `allowedVersions` filters silently

There is no log line when a version is filtered out. The `Filtered out N disabled update(s)` message
belongs to `enabled: false`, not to `allowedVersions`. To verify a pin, compare the total at
`flattened updates found` with `LOG_LEVEL=debug` before and after.

### Not every breaking change is a major

Four of our eight pins were not SemVer major bumps. A `<major+1` bound would not have stopped them.
Always take the real target version from a dry run before choosing a bound.

The sneakiest variant moves the target framework. One build-tooling package switched its modern
assets from the current .NET major to the next one within a **minor** release: the last good version
still shipped assets for your framework, the next minor only for the newer one. The name-based guard
rail does not catch this, because the package is not in its families. Pin it below that minor, and
lift the pin when the package supports your framework again or when you move framework.

Deprecations behave the same way. A member is usually marked obsolete in a minor and removed in the
next major, so when a build fails on a deprecated API, the bound goes below the version that
*introduced the deprecation*, not below the next major. See
[working with pull requests](working-with-prs.md#10-the-build-fails-on-a-deprecated-api).

### A pin that excludes the current version is permanent, not temporary

If the bound excludes the version you are actually on, the package is blocked forever and nothing
reports it. Compare every bound against your manifest before committing it.

### "The package disappeared from the update set" is the wrong success criterion

A bump *within* the allowed line should still be proposed. We watched a package go from a proposed
3.10.2 to a proposed 1.6.31 — still present, correctly constrained. If a package vanishes entirely
after you add a pin, that is a signal the pin is too tight, not that it worked.

### `matchPackageNames` with a bare name is an exact match

Not a prefix. List `Refit`, `Refit.HttpClientFactory` and `Refit.Xml` separately. The upside is that
it will not accidentally catch something like `AspNetCore.HealthChecks.Azure.Storage.Blobs`.

### A central entry outlives the package that needed it

Renovate updates every `PackageVersion` in `Directory.Packages.props`. It never checks whether a
project still references it. Remove the last reference and the entry stays, and Renovate keeps
updating it in the NuGet group pull request. The same goes for a transitive pin whose parent has
since caught up: it does nothing, but it still looks like a security floor and still gets updates.
Neither breaks a build, so nobody notices. A [package guard](package-hygiene.md) on every pull
request that touches package files catches both.

---

## Pipeline

### Pointing `RENOVATE_CONFIG_FILE` at your own `renovate.json` loads it twice

**Symptom.** Statistics exactly double: every `customManager` and every `packageRule` appears twice
in `--print-config`.

**Cause.** Renovate already reads `renovate.json` from the repository. Setting the variable loads
the same file *again* as global config, and the arrays are merged rather than replaced. Every
dependency is then processed twice; the second pass reports `Cannot find replaceString in current
file content. Was it already updated?` and the change for that file is dropped.

**Fix.** Do not set the variable. It belongs only with a throwaway config containing a `force`
block, because `force` overrides instead of merging.

**Diagnosis.** Run the same extraction with and without the variable and compare the counts.

> A warning from our own history: we blamed a nearly-empty pull request on this and were wrong.
> Removing the variable halved the `Cannot find replaceString` count, which looked like progress,
> but the pull request stayed empty. The real cause was the one below. If you fix this and the
> symptom persists, the doubling was aggravating a second problem rather than causing it.

### A regex manager that swallows the line ending updates nothing

**Symptom.** A custom regex manager detects everything correctly — the statistics are right, the
branch is created, the pull request exists — but it contains one or two files instead of dozens.
The log is full of `Cannot find replaceString in current file content. Was it already updated?`
followed by `No content changed`.

**Cause.** A `matchString` that ends in `\s` makes the delimiter part of the match, so it lands in
Renovate's `replaceString`. On a Windows agent that delimiter is usually the `\r` of a CRLF line
ending, because git checks out with `core.autocrlf=true`. The update step then looks for
`task: AzureCLI@2\r` in content that is stored LF-only, does not find it, and silently drops that
file's change.

The giveaway is in the debug log, one line apart: `"replaceString": "task: AzureCLI@2\r"` while the
`"existingContent"` beside it contains only `\n`.

What made this hard to see is that it fails *almost* everywhere. In our repository exactly one of
233 references happened to be followed by trailing spaces rather than the line ending, so its
`replaceString` ended in a space, matched fine, and produced a pull request containing precisely
that one file. A pull request with one file looks like a small update; a pull request with none
would have been investigated months earlier.

**Fix.** Make the delimiter zero-width:

```diff
- "matchStrings": ["task:\\s*(?<depName>[A-Za-z0-9_.\\-]+)@(?<currentValue>\\d+)\\s"]
+ "matchStrings": ["task:\\s*(?<depName>[A-Za-z0-9_.\\-]+)@(?<currentValue>\\d+)\\b"]
```

Use `\b`, **not** a lookahead such as `(?=\s)`. Renovate prefers RE2, and RE2 supports neither
lookahead nor lookbehind. On an agent where RE2 fails to load a lookahead works by accident and
breaks the day it loads successfully.

**Diagnosis.** Run a dry run at debug level and count how many `"replaceString"` values contain
`\r`. Before our fix it was 232 of 233; after, zero, with the detected dependency count and the
branch set unchanged.

**Generalise it.** Any `matchString` whose match extends to the end of the line has this problem,
not just task versions. Keep the captured text to the part you actually intend to replace.

### Renovate's own output can execute pipeline commands

**Symptom.** Build tags appear out of nowhere, or the step turns red with logging issues while
Renovate finished successfully.

**Cause.** The agent executes any `##vso[...]` command that appears in step output — including
mid-line. Renovate logs the contents of matched files at debug level, so a pipeline YAML containing
such a command as a string will have it executed.

**Fix.** Filter every occurrence, unanchored:

```powershell
npx --yes renovate@$(RenovateVersion) 2>&1 | ForEach-Object { "$_" -replace '##(?=(vso)?\[)', '# #' }
```

Anchoring on line start is not enough: our trigger was a `Write-Host "##vso[task.logissue ...]"`
in the middle of a line. `logFile` and `logFileLevel` do not exist in the self-hosted options, so
writing to a file instead is not an alternative.

### Renovate reads its config from the default branch, always

**Symptom.** A config change on a feature branch has no effect, even with `baseBranchPatterns`
pointing at that branch.

**Cause.** Repository config comes from the default branch, and repository config beats admin
config. A rule on the default branch wins over your branch.

**Fix.** For a faithful pre-merge test, push the complete branch config through `RENOVATE_FORCE`,
which has the highest priority. See [pre-merge-testing.md](pre-merge-testing.md).

### `PowerShell@2` dot-sources your script

**Symptom.** The step succeeds and does nothing at all.

**Cause.** The task runs `. 'script.ps1'`, so a guard like
`if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }` never fires.

**Fix.** Define only functions in the script and call the entry point explicitly:
`. script.ps1; Invoke-Main`.

### Without a .NET SDK on the agent there are no lock files

Renovate regenerates `packages.lock.json` by running `dotnet restore`. Installing Node is not
enough. Add `UseDotNet@2`, and note that `binarySource` falls back to `global` outside a
Containerbase environment, which means Renovate uses whatever is on the agent PATH.

### A successful restore can still lose every lock file, because of a welcome banner

**Symptom.** The pull request carries an "Artifact update problem" comment and contains a handful of
lock files instead of hundreds. Build validation then fails with `NU1004` — lock file inconsistent
with the project — rather than the `NU1109` you would expect from a genuine version conflict.

**Cause.** Look at the `artifactErrors` entry in the log and read the `stderr` beside it. Ours
contained no error at all:

```
Welcome to .NET 10.0!
---------------------
SDK Version: 10.0.401
Installed an ASP.NET Core HTTPS development certificate.
```

That is the .NET first-run experience. The restore itself **succeeded** — the `stdout` of the same
invocation says `Restored ...`. But Renovate treats non-empty stderr as a failed artifact update and
discards the regenerated lock files for the entire scope. In our case that was 270 of 291 files,
thrown away because of a greeting.

The first-run experience is printed **once per user profile**, which produces two confusing effects.
Only the very first restore is affected, so a second `updateArtifacts` scope running afterwards
succeeds normally — that is why a handful of our lock files did make it into the pull request, all
of them from a project subtree with its own `Directory.Build.props`. And because it is per profile,
it hits one agent in a pool and not the next, so it looks intermittent.

It surfaces after an SDK upgrade. Ours appeared the first Renovate run after `global.json` moved to
a new patch version.

**Fix.** Two measures, and it is worth having both:

1. Absorb the banner before Renovate starts, with a `dotnet --version` step after `UseDotNet@2`.
2. Set `RENOVATE_CUSTOM_ENV_VARIABLES` to `{"DOTNET_NOLOGO":"1","DOTNET_CLI_TELEMETRY_OPTOUT":"1"}`.

**The trap inside the fix.** Setting `DOTNET_NOLOGO` in the pipeline step's own `env` does nothing.
Renovate hands child processes a fixed environment allow-list, which the log prints verbatim:

```
NUGET_PACKAGES, MSBUILDDISABLENODEREUSE, HOME, PATH, NODE_EXTRA_CA_CERTS, PROGRAMFILES,
PROGRAMFILES(X86), APPDATA, LOCALAPPDATA, PROCESSOR_ARCHITECTURE, PATHEXT, CI
```

Anything outside that list never reaches `dotnet restore`. `customEnvVariables` is the supported way
in.

**Generalise it.** An `artifactErrors` entry does not prove the command failed. Read the `stdout`
next to it first: if it reports success, your problem is whatever wrote to stderr — a banner, a
deprecation notice, a proxy warning — and not the restore.

### One failing project costs the whole lock file scope

**Symptom.** The NuGet group pull request contains ten lock files out of nearly three hundred, without
any banner in the log.

**Cause.** Renovate rejects lock file updates per `updateArtifacts` scope, not per project. If the
restore of a single project fails — we hit `NU1109` in one test project — every other lock file in
that scope is dropped with it.

**Fix.** Search the log for `Failed to restore` and look at that one project. The usual culprit is a
transitive requirement that collides with a pin; see the next pitfall.

### A pin can force a second pin

A central pin such as `Microsoft.OpenApi < 2` also blocks every package that transitively requires a
higher version. In our case a test library moved to a converter that demands `Microsoft.OpenApi >= 3`,
which produced `NU1109` and, through the pitfall above, an almost empty NuGet pull request. The fix is a
second pin on that library, with a `description` saying it must be lifted **together** with the first.

**Measure the boundary; do not read it off the error.** The failing pull request contained version
2.17.0, but 2.16.0 already broke. Two ways to find it:

- Read the dependency chain per candidate version from the nuspec at
  `https://api.nuget.org/v3-flatcontainer/<id>/<version>/<id>.nuspec`. Dependencies are often listed
  only inside `<group>` elements, so do not expect a flat `<dependency>` list.
- Bump the version locally, run a plain `dotnet restore` on the affected project and see whether
  `NU1109` appears. Revert both the props file and the lock file it touched afterwards.

### Miscellaneous agent facts worth knowing up front

- Renovate 44+ requires **Node >= 24** — it uses `RegExp.escape`.
- A Windows pool has no `bash`. Every step must be `powershell` or `pwsh`, and each needs an
  explicit `if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }` because PowerShell does not propagate
  the exit code by itself.
- `Cannot find module 're2'` on a Windows agent is harmless; Renovate falls back to `RegExp`.
- If the pipeline starts outside Renovate's own `schedule` and `updateNotScheduled` is `false`, the
  run finds updates and creates nothing. That is correct behaviour and looks exactly like a bug.

---

## Azure DevOps platform behaviour

### A closed pull request blocks its own recreation, and you cannot unblock it

**Symptom.** An expected update never arrives. The log says
`Closed PR #<id> already exists. Skipping branch.`

**Cause.** With the default `recreateWhen: auto`, Renovate refuses to recreate a pull request whose
title matches one that was closed. The check is **unconditional** — recreating the branch does not
help, because the check does not depend on whether the branch exists.

**What does not work on Azure DevOps:**

| Escape | Why not |
|---|---|
| Rename the abandoned pull request | `TF401181`: a pull request in that state cannot be edited |
| Tick a box on the Dependency Dashboard | There are no checkboxes; see below |
| `recreateWhen: "always"` | Crashes: `TypeError: Cannot read properties of null (reading 'length')` in the onboarding check |
| Delete the pull request | Azure DevOps cannot delete pull requests |

**What does work:**

1. **Wait** for a newer version. Different title, fresh pull request. Cleanest route.
2. **Reactivate** the closed pull request (status back to Active), which requires *both* the source
   and target branch to exist. Restore them temporarily if needed, then rename it so the title is
   free again, then abandon it once more.

Note the asymmetry: **grouped** pull requests come back on their own (`recreateClosed is true`),
only per-package ones stay blocked. And a **merged** pull request blocks nothing — the check only
applies to abandoned ones.

### The Dependency Dashboard does not work on Azure DevOps

It is listed in Renovate's own FAQ under
[core features not supported on all platforms](https://docs.renovatebot.com/faq/#renovate-core-features-not-supported-on-all-platforms).
It needs issues with interactive Markdown checkboxes, which Azure DevOps work items do not have.
What you get is a read-only page truncated at 4000 characters.

Turn it off with `dependencyDashboard: false` and get your overview from the pull request list and
the run notification instead. Keep `azureWorkItemType` set anyway: without it Renovate falls back to
type `Issue`, which does not exist in most Azure DevOps processes.

### Renovate leaves a branch alone once you commit to it

As soon as a commit from a different git author lands on a Renovate branch, the pull request counts
as *modified*: no more version bumps, no more rebases. If the branch later becomes obsolete Renovate
does not clean it up but renames the pull request to `... - abandoned`.

This matters when you are tempted to revert one package inside a group pull request. See
[working-with-prs.md](working-with-prs.md) for when that trade-off is worth making.

### An abandoned group pull request comes back on its old branch

Most group pull requests are recreated after you abandon them, which is easy to read as "abandon, and
the next run builds a fresh one". It does not. Abandoning leaves the `renovate/<group>` branch in
place, and while it exists Renovate logs `branchExists=true`, `Branch does not need rebasing`,
`reuseExistingBranch=true` and `No package files need updating` — and runs no restore at all. A config
fix you merged in the meantime, such as a pin or the banner workaround, never reaches that pull
request.

To force a rebuild, abandon the pull request **and** delete the branch. The next run then logs
`Branch needs creating` and regenerates every lock file. Leave branches alone whose content is fine.

### Renovate tries to close its own issues with a state your process may not have

Even with the dashboard off, every run calls `ensureIssueClosing` for four fixed titles:
`Dependency Dashboard`, `Action Required: Fix Renovate Configuration`,
`Action Required: Add missing credentials` and `Action required: Add a Renovate config`. If it finds a
work item with one of those titles (a `[<repository>] ` prefix is ignored), it sets `State=Closed`.
A Scrum `Task` only knows *To Do*, *In Progress*, *Done* and *Removed*, so the call fails with
`Error closing issue` and `The field 'State' contains the value 'Closed' that is not in the list of
supported values` — and the Renovate step turns red although every pull request was created fine.

The usual trigger is the old dashboard work item, left behind after you switched the dashboard off.
Rename it so the title no longer matches. Deleting may not be an option: in our organisation both the
CLI and a REST `DELETE` reported success while the work item stayed exactly as it was, because the
*Delete work items* permission was missing. Verify afterwards with a query on those four titles.

We only saw this in runs without the pre-merge harness, which makes it easy to miss during testing
and then hit on the first scheduled run.

### Permissions, and what each missing one looks like

The build service identity needs Contribute, Contribute to pull requests, Create branch and Read on
the repository, plus View project-level information. Add Packaging Read on any private Azure
Artifacts feed, and — only if you use the work item step — permission to create and edit work items
in the target area path.

| Symptom | Missing |
|---|---|
| `TF401027: You need the Git 'CreateBranch' permission` | Create branch |
| Branches are not pushed at all | Contribute |
| `TF401027: You need the Git 'PullRequestContribute' permission` | Contribute to pull requests |
| Branches are pushed but no pull requests appear | Same as above |
| `statusCode=401` for `pkgs.dev.azure.com`, and pull requests without lock files | Packaging Read on the feed |
| The work item step fails creating the run item | Work item permissions on the area path |

Do not grant more than that. Renovate needs no *Delete work items* (the work item step only moves
items to Done or Removed), and no *Bypass policies* or *Force push*: it only ever proposes changes
through pull requests.

Do not let the commit author mislead you. The commits say `Renovate Bot` — Renovate's own default
git author, which wins over any `git config` in the pipeline — but the identity that pushes, creates
pull requests and reads feeds is the build service. Permission problems are always about the build
service.

When you ask an administrator for a fix, give them the identity's exact name, the repository or
feed, the exact error line and the build number. "Renovate does not work" gets you nowhere.

If this regresses after having worked, check whether "Limit job authorization scope to current
project" was switched on: that forces the project-scoped build service, which may not hold the
permission.

---

## Notifications

### The Teams webhook needs the full envelope, not a bare card

The Power Automate trigger "When a Teams webhook request is received" iterates over
`body.attachments`. A bare Adaptive Card makes the flow fail on a null array. Send exactly one
attachment:

```json
{ "type": "message",
  "attachments": [ { "contentType": "application/vnd.microsoft.card.adaptive",
                     "contentUrl": null,
                     "content": { } } ] }
```

### HTTP 202 proves nothing

The trigger accepts asynchronously and returns 202 even when the flow fails immediately afterwards.
Do not report success on the status code. The `x-ms-workflow-run-id` response header gives you the
run id to check the actual outcome.

### `-match` is case-insensitive, which makes `branch=` read `baseBranch=`

Renovate's log context contains both. A naive `branch=` pattern silently reads the base branch.
Use a negative lookbehind: `(?<![A-Za-z])branch=`.

### Do not detect blocked branches by group name

It is tempting to assume group branches always have `recreateClosed: true` and filter them out. They
do not. We measured a run where three group branches from our own config ran *with* "recreating
closed PRs is disabled". Filtering on group names would have hidden real blockages. Parse the log.

### An undefined pipeline variable arrives as its own name

`$(SomeVariable)` that does not exist comes through literally as the string `$(SomeVariable)`, not as
empty. Without an explicit check your script will cheerfully POST to that text.

---

## npm specifics

| Error | Meaning | Handling |
|---|---|---|
| `ERESOLVE` | Peer dependency conflict. Two packages from the same ecosystem must bump together | Group them (`mui`, the TypeScript toolchain, `vitest`, `playwright`) |
| `EOVERRIDE` | A fixed version in `overrides` conflicts with the new version of a direct dependency | Point the override at the dependency: `"pkg": "$pkg"`. If the package is only transitive, add it to `dependencies` first |

`EOVERRIDE` has a particularly misleading failure mode: the branch is created, the log says
`No package files need updating` and `No files to commit`, the step does **not** turn red, and no
pull request appears. When a group pull request goes missing, look at lock file regeneration before
you look at the closed-pull-request check.

### An override on a package that is only transitive breaks too

The `"$pkg"` reference only works when the package is a direct dependency. Renovate passes every bumped
package to npm as a direct install argument, so a fixed-range override on a purely transitive package
fails with the same `EOVERRIDE`. Declare the package in `dependencies` (not `devDependencies` if the
lock file marks it as production) and then switch the override to `"$pkg"`. Editing the two root
entries of `package-lock.json` by hand is enough; regenerating the whole lock file produced hundreds of
unrelated changes.

### npm can nest a second copy silently

Some ecosystems release their packages on different schedules. When `@playwright/test` and
`playwright-core` moved to a new minor while the experimental component-testing packages stayed
behind, npm did not raise `ERESOLVE`. It quietly installed a second `playwright-core` under the
lagging package, and TypeScript then rejected every test with hundreds of `TS2345` errors, because
types from two copies of the same package are incompatible.

A group (without `matchUpdateTypes`) keeps such packages together, but it cannot move a package to a
version that does not exist. When the lagging package has no matching release, pin the whole family
below the new version and track the migration in a work item. To spot the problem in a pull request,
look in the lock file diff for nested paths like `node_modules/<pkg>/node_modules/<other-pkg>`.

### A lock-file-only npm pull request is correct

With npm's default `rangeStrategy: replace`, Renovate only touches `package.json` when the new version
falls outside the existing range. Every minor and patch bump stays inside `^x.y.z`, so only
`package-lock.json` changes. Expect `package.json` to change on majors only.

### A local dry run cannot prove an npm pin

Without feed credentials every npm lookup in a `--platform=local` run fails with `401`, so Renovate
finds no npm updates at all and still exits `0`. A before-and-after comparison of a new npm pin
therefore shows no difference. Validate the config, check the boundary against the lock file, and let
the next pipeline run prove the effect.
