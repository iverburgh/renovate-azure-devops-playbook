# Configuration

The reference configuration is [config/renovate.json](../config/renovate.json), and every rule in it
carries a `description` explaining itself. This page covers the decisions *behind* those rules — the
things a `description` field is too small for.

## The shape of it

Three files work together:

| File | Role |
|---|---|
| `renovate.json` | What Renovate does: which managers, which groups, which bounds |
| `pipelines/renovate.yml` | When and where it runs, and with what credentials |
| `pipelines/variables/renovate-version.yml` | The pinned Renovate version, in one place so Renovate can bump it |

Secrets never appear in `renovate.json`. Feed credentials go through `RENOVATE_HOST_RULES` in the
pipeline, the notification webhook through a secret pipeline variable.

## Scheduling

```json
"schedule": ["* 0-4 * * 2"],
"updateNotScheduled": false,
"timezone": "Europe/Amsterdam"
```

Two schedules have to agree: Renovate's own (above, in your timezone) and the pipeline's cron (in
UTC). If the pipeline starts outside Renovate's window with `updateNotScheduled: false`, the run
finds updates and then creates nothing at all. It looks broken and is not.

Renovate's cron dialect needs five fields with `*` for minutes.

## Rate limits

```json
"prConcurrentLimit": 0,
"prHourlyLimit": 10
```

`prConcurrentLimit` caps how many pull requests may be **open simultaneously**, not how many a run
may create. There is no per-run option. Because a weekly run finishes well inside an hour,
`prHourlyLimit` is effectively the per-run cap.

We started with `prHourlyLimit: 2` and got exactly two pull requests a week, which is not obviously
wrong until you notice the backlog never shrinks. With grouping in place a run produces perhaps
three to six branches anyway, so the limit rarely binds. Zero concurrent means a backlog of open
pull requests never starves a new run.

## Release notes need a github.com token

On any platform other than github.com, Renovate skips release notes for every dependency whose
source repository is on github.com unless it has a token for github.com. The debug log says
`No github.com token has been configured. Skipping release notes retrieval`, and the pull request
body has no changelog. Many NuGet and npm packages keep their source on GitHub, so this affects a
large share of updates.

The fix is a personal access token for github.com, from any account, with read-only access to
public data only. Pass it as `RENOVATE_GITHUB_COM_TOKEN`. It also raises the GitHub API rate limit
for some of Renovate's other lookups. See
[running Renovate](https://docs.renovatebot.com/getting-started/running/).

Store it as a secret pipeline variable and map it explicitly in the step's `env:`. The pipeline
includes the line commented out. Uncomment it only once the variable exists: an undefined variable
arrives as its own name, and Renovate would then use the literal text `$(...)` as the token.

We did not run with this token in production, so our pull requests had no release notes for
GitHub-hosted packages.

## Which files get scanned

```json
"enabledManagers": ["nuget", "npm", "bicep", "nvm", "custom.regex"]
```

| Manager | Picks up | Produces |
|---|---|---|
| `nuget` | `Directory.Packages.props`, `*.csproj`, `global.json` | NuGet packages and the .NET SDK |
| `npm` | every `package.json` with a sibling lock file | npm packages |
| `bicep` | `*.bicep` | Azure REST API versions of resource declarations, never modules |
| `nvm` | `.nvmrc` | The Node version |
| `custom.regex` | whatever your patterns say | Renovate itself and Azure DevOps task versions |

Two things to keep in mind. An **empty** `enabledManagers` means *all* managers, not none — never use
that array to switch something off. And a custom manager only counts when listed with its
`custom.` prefix; `"regex"` on its own is silently ignored, even though the statistics call it
`regex` afterwards.

Extracting more files than you intend is harmless: extraction only reads. What produces pull
requests is the update step, and that is what `packageRules` controls.

## Rule order is functional

Renovate evaluates **every** `packageRule` and merges the ones that match. Where two matching rules
set the same property, the **last one wins**. The order in the file is therefore behaviour, not
formatting.

That is why the reference config is laid out the way it is: broad grouping rules first, then the
narrower guard rails and pins that must override them. Move a pin above its group and it still
applies, but move a second `groupName` below the first and the package quietly changes groups.

When a package ends up somewhere unexpected, read the rules top to bottom and track which ones match
it — not just the one you were thinking of.

## Cooldown: a minimum release age

```json
{ "matchDatasources": ["npm", "nuget"], "minimumReleaseAge": "3 days" },
{ "matchDatasources": ["nuget"], "matchPackageNames": ["/^<YourCompany>\\./i"], "minimumReleaseAge": null }
```

A compromised package release is usually detected and pulled within days. With
[`minimumReleaseAge`](https://docs.renovatebot.com/configuration-options/#minimumreleaseage) Renovate
proposes the newest version that is at least that old, so a release that gets pulled never reaches a
pull request. The two rules sit at the top of `packageRules`.

The details are where it goes wrong:

- **Key on the datasource, not the manager.** `matchDatasources` also covers the .NET local tools in
  `.config/dotnet-tools.json` and the Renovate self-update, which arrive through other managers.
- **Never set it top-level.** The `azure-pipelines-tasks` and `azure-bicep-resource` datasources
  publish no release timestamp. Under the default `minimumReleaseAgeBehaviour` of
  `timestamp-required`, an update without a timestamp stays pending forever. The debug log says
  `Marking N release(s) as pending, as they do not have a releaseTimestamp`, and the task and Bicep
  groups simply stop appearing, without an error.
- **Exempt with `null`, not `"0 days"`,** and put the exemption *after* the general rule: the last
  match wins. Exempting your own internal packages is reasonable; you trust their source.
- **Leave `internalChecksFilter` at `strict`.** Strict picks the newest version that is old enough and
  creates no branch when none is. With `flexible`, Renovate opens a pull request for the newest
  version straight away, and that pull request then jumps between versions as they age.
- **Expect a longer wait than three days.** The age, plus Renovate's default
  `minimumReleaseAgeBuffer` of 30 minutes, plus a weekly schedule: a release that is just too young
  for this week's run waits for next week's. Count on up to about ten days.
- **Security fixes wait too.** `vulnerabilityAlerts`, which could bypass the cooldown, only works on
  GitHub. When an update is urgent, make it by hand in an ordinary pull request; do not loosen the
  rules for it.

To see it working, search the debug log for `newVersionAgeInDays` (3 or more on a proposed npm or
NuGet update) or `pendingChecks: true` (an update held back for now). Task, Bicep and exempted
internal updates should show no `pendingChecks`, and `Marking N release(s) as pending` should not
appear at all; if it does, the cooldown is hitting a datasource without release timestamps.

> We introduced the cooldown without a test run beforehand, so unlike most of this playbook it is not
> yet confirmed by a real run. Check the log of the first scheduled run after introducing it.

## Grouping

The decisions here are the substance of the whole configuration, and the reasoning lives in
[pitfalls.md](pitfalls.md). In short:

| Ecosystem | Grouping | Why |
|---|---|---|
| NuGet | Everything in one | Mandatory under Central Package Management; any split gives `NU1109` |
| npm minor+patch | One group | Safe, npm is not centrally pinned |
| npm majors | One per package | Reviewed individually |
| npm coupled ecosystems | Grouped explicitly | Peer dependencies must move together |
| Bicep | One group | Splitting per provider multiplies build fan-out |
| SDK, Node, Renovate itself | Own group each | Different cadence, different risk |
| Pipeline tasks | One group | Touches many files; better as one reviewable change |

`separateMajorMinor` and `separateMinorPatch` are both `false`, with grouping done explicitly
through `groupName` instead. That is deliberate: it puts the decision in one place you can read,
rather than spread across two booleans and their interaction.

We also write the rules out rather than extending Renovate's
[config presets](https://docs.renovatebot.com/presets-config/) or
[group presets](https://docs.renovatebot.com/presets-group/), because a preset that changes upstream
changes your dependency policy without a pull request. That trade-off may fall the other way for
you — the presets are well maintained and save a lot of typing.

## Guard rails versus temporary pins

Two kinds of `allowedVersions` exist in the config and they should not be confused.

A **guard rail** is structural. The `<11` bound on the runtime-bound .NET package families is there
because Renovate does not filter NuGet on target framework — `constraintsFiltering` does not support
that datasource — so without it a new .NET major would immediately be proposed for packages your
project cannot use. That bound moves when you move framework, not before.

A **temporary pin** parks a specific breaking change. The convention that makes this work is that
every pin's `description` names both the reason *and* the work item that lifts it. A pin without an
exit is a pin that quietly becomes permanent.

Three things to get right when adding one, all expanded in [pitfalls](pitfalls.md#pins): the bound
must not exclude your current version, not every breaking change is a major, and `allowedVersions`
filters without logging anything.

## Custom managers

Two of them, both regex.

**Renovate updates itself** by matching the version line in the pipeline variables file. This closes
a real gap: otherwise the one dependency nobody watches is the tool doing the watching.

**Azure DevOps task versions** are matched by regex rather than by the native manager, which skips
any file containing template expressions — 38% of ours. The details are in
[pitfalls](pitfalls.md#the-native-azure-pipelines-manager-silently-skips-files).

Both report as `regex` in the statistics, so group on `matchDatasources` and not on `matchManagers`.

## Things deliberately switched off

| Setting | Value | Why |
|---|---|---|
| `dependencyDashboard` | `false` | Does not work on Azure DevOps; needs interactive checkboxes |
| `automerge` | `false` | Every update gets human review |
| `RENOVATE_CONFIG_FILE` | not set | Setting it loads your config twice and drops file edits |

The last one is an absence rather than a setting, which is why both pipelines carry a comment saying
so. An absent variable is invisible; someone will helpfully add it back.

`azureWorkItemType` stays set even with the dashboard off. Without it Renovate falls back to type
`Issue`, which most Azure DevOps processes do not have.

## Moving to the next framework major

The pattern is the same for every runtime, and the order matters. The pins are the **last** thing
you change, not the first.

**Follow LTS majors only.** A short-term-support release is supported for too short a time to be
worth a migration. For .NET that means skipping the odd majors: .NET 11 is STS, so from 10 the next
step is 12.

Before touching the pins, confirm:

- Your hosting platform supports the new runtime, and so do your build agents.
- Any runtime version set in your deployment pipelines and infrastructure templates has been
  updated — for an App Service or Functions app, the runtime stack (for example
  `DOTNET-ISOLATED|10.0` or `DOTNETCORE|10.0`). This is the one people miss, because it is usually a
  hardcoded string in a Bicep file or a pipeline parameter rather than a version in a manifest.
  Search for the current version string; it should return zero hits afterwards.
- Your version manifests (`global.json`, `.nvmrc`) point at the new version.
- Your target framework has been migrated, as its own piece of work.
- If you gate on deprecated APIs (see
  [working with pull requests](working-with-prs.md#10-the-build-fails-on-a-deprecated-api)), the
  `SYSLIB` range in `.editorconfig` runs up to the last obsoletion of the new version. Otherwise
  every newer obsoletion stays a warning and slips through.

Only then move the bounds, together. For .NET that means the SDK pin and the package family guard
rail at the same time — `/^10\./` and `<11` become `/^12\./` and `<13`. Move only one and you get
either an SDK ahead of its packages or packages ahead of their SDK. Renovate then delivers the
package updates in the ordinary NuGet group.

Then re-read your temporary pins. Some of them exist because a package expected a newer runtime, and
those can go. Also check packages that follow the .NET line but fall outside the guard rail's name
patterns; the PowerShell SDK is one (7.4 targets .NET 8, 7.5 .NET 9, 7.6 .NET 10), and nothing in the
config stops it from moving ahead of your framework.

### Node

Node follows the same pattern with one extra wait. A new Node LTS is only usable once your hosting
platform offers it as a runtime, which can take weeks: Node 24 became LTS in October 2025 and arrived
on Azure App Service in November 2025.

The runtime of a Node web app is often set in two places — the app deployment pipeline (for example
a `node|24-lts` runtime stack) and the infrastructure template (`linuxFxVersion`, including any
staging slot). Change both in the same step: the infrastructure deployment sets one, the application
deployment the other, and whichever deploys last decides which runtime stays. Afterwards a search
for `node|24-lts` should return nothing.

Keep the `v?` in the Node pin (`/^v?26\./`), see
[pitfalls](pitfalls.md#the-node-datasource-returns-versions-with-a-v-prefix). And you cannot go lower than 24:
Renovate 44+ requires it.
