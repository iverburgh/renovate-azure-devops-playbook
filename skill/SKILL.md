---
name: renovate-azure-devops
description: Configure, debug and review self-hosted Renovate on Azure DevOps Pipelines. Use when writing or changing renovate.json, building the Renovate pipeline, grouping dependency updates, fixing missing lock files in a Renovate pull request, investigating why an expected update never appears, or setting up work item tracking and run notifications. Covers NuGet with Central Package Management, npm, Bicep API versions, the .NET SDK, Node and Azure DevOps task versions. Triggers on 'renovate', 'renovate.json', 'dependency updates', 'dependency bot', 'renovate pipeline', 'packages.lock.json', 'NU1109', 'ERESOLVE', 'EOVERRIDE', 'artifact update problem', 'renovate-config-validator', 'dry-run', 'allowedVersions', 'packageRules', 'azure-pipelines-tasks'.
---

# Renovate on Azure DevOps

Operational knowledge for running self-hosted Renovate on Azure DevOps. Everything here has been
verified against real pipeline runs, unless marked otherwise; treat it as settled and do not
re-derive it.

The reasoning behind each item lives in [../docs/pitfalls.md](../docs/pitfalls.md). This file is the
short form plus the behaviour rules.

## Mandatory self-check

After **every** change to `renovate.json`, `renovate.json5` or `config.js`, run both of these
without being asked. The change is not finished until both are clean.

```powershell
# 1. Schema and syntax. No file argument - with a path it switches to global-config mode.
npx --yes --package renovate@<version> -- renovate-config-validator --strict

# 2. Behaviour. Run from the repository root.
npx --yes renovate@<version> --platform=local --onboarding=false --dry-run=full
```

Constraints on the dry run:

- Requires Node 24 or newer. On Node 22 it crashes with `RegExp.escape is not a function`.
- `--platform=local` requires `--onboarding=false`.
- **Never** set `RENOVATE_CONFIG_FILE` to the repository's own config. It loads twice and merges.
- Package lookup failures against a private feed are normal locally.
- Info level only reports extraction statistics. Branch names and proposed versions need
  `LOG_LEVEL=debug`; grep `"branchName"` and `flattened updates found`.

### Prove a change, do not assert it

For grouping or pin changes, produce a before-and-after, not a snapshot. Take the baseline by
stashing the config (`git stash push -- renovate.json`), measuring, then popping.

- **Adding a manager:** the `fileCount`/`depCount` of every existing manager must be unchanged and
  only the new one appears.
- **Adding a pin:** the branch set must be **identical** — `allowedVersions` filters candidate
  versions and never affects grouping. Only the update total should move.

To try an idea without touching the repository config, point `RENOVATE_CONFIG_FILE` at a throwaway
file containing a `force` block. `force` overrides rather than merges, which is also why it is the
only safe use of that variable.

## Decisions that are settled

| Question | Answer |
|---|---|
| NuGet grouping under Central Package Management | Everything in **one** pull request. Any split produces `NU1109` |
| npm grouping | minor+patch together; majors one per package; coupled ecosystems grouped explicitly |
| Coupled npm clusters | No `matchUpdateTypes` on them — a peer range can break on a *minor*, and that minor would then land in the generic group and break its lock file regeneration |
| Bicep grouping | One pull request. Per-provider splits multiply build fan-out instead of isolating it |
| Bicep API versions | `maxMajorIncrement: 0`, exclude preview via `matchCurrentValue` |
| Azure DevOps task versions | Custom regex manager, never the native one. `extractVersion` is required |
| Dependency Dashboard | Off. Unsupported on Azure DevOps |
| Auto-merge | Off |
| Auth | `System.AccessToken`, never a personal access token |
| Cooldown | `minimumReleaseAge` in a package rule on `matchDatasources: ["npm", "nuget"]`, never top-level; internal packages exempted with `null` in a later rule. *Not yet confirmed by a production run* |
| Framework majors | LTS only. Move the runtime-family bound and the SDK bound together, and extend the `SYSLIB` range in `.editorconfig` |
| Build fails on a deprecation (`CS0618`, `SYSLIB`) | Pin below the version that introduced it (default), or a scoped `#pragma` with a work item id when the update is needed now. Never `NoWarn`, lowered severity or `SuppressMessage` |

## Things that fail silently

These produce no error, so an agent must check them deliberately.

- **`enabledManagers: []` means ALL managers.** An empty array is treated as unset.
- **Custom managers need the `custom.` prefix** in `enabledManagers` (`custom.regex`, not `regex`).
  Without it the manager never runs. Confusingly, the statistics still call it `regex` — so group on
  `matchDatasources`, not `matchManagers`.
- **`allowedVersions` filters without logging.** `Filtered out N disabled update(s)` belongs to
  `enabled: false`. Verify with the update total instead.
- **A pin excluding the current version is permanent.** Always compare the bound against the
  manifest.
- **The node datasource returns a `v` prefix.** `/^24\./` matches nothing; use `/^v?24\./`.
- **The native azure-pipelines manager skips files containing `${{ }}` expressions** — silently, and
  in our case that was 38% of them.
- **A `matchString` ending in `\s` swallows the line ending into `replaceString`.** On a Windows
  agent that is a CR, which is absent from the LF content the update is applied to, so every change
  is dropped with `Cannot find replaceString`. Use a zero-width `\b`; never a lookahead, because
  RE2 does not support one.
- **`RENOVATE_CONFIG_FILE` pointed at your own config loads it twice** and drops file edits from the
  pull request. Symptom: statistics exactly doubled.
- **An undefined pipeline variable arrives as the literal string `$(Name)`**, not as empty.
- **A run outside Renovate's own `schedule` with `updateNotScheduled: false` creates nothing.**
- **Non-empty stderr fails an artifact update even when the command succeeded.** The .NET first-run
  banner after an SDK upgrade is enough to discard every regenerated lock file in a scope. Absorb it
  with a warm-up step and set `RENOVATE_CUSTOM_ENV_VARIABLES` — a plain step-level `DOTNET_NOLOGO`
  never reaches the child process, because Renovate passes a fixed environment allow-list.
- **One failing project discards the lock files of its whole scope**, not just its own.
- **An abandoned group pull request is reused, not rebuilt, while its branch exists.** Delete the
  `renovate/<group>` branch to make a config fix reach the pull request.
- **npm can nest a second copy of a package instead of raising `ERESOLVE`**, which surfaces only as
  hundreds of `TS2345` errors in the build. Grouping cannot help when the lagging package has no
  matching release; pin the family instead.
- **A notification moved to its own job loses everything from the first job**: the log, the run result
  (`Agent.JobStatus` now describes the notification job), output variables without `isOutput=true`, and
  a usable start time. Each loss produces a wrong message, not an error.
- **A local dry run finds no npm updates without feed credentials** and still exits `0`, so it cannot
  prove an npm pin.
- **A top-level `minimumReleaseAge` makes the task and Bicep groups vanish.** Their datasources
  publish no release timestamp, so the updates stay pending forever.
- **A secret pipeline variable is not in the step environment** unless mapped with `env:`, and a
  variable group not authorised for the pipeline fails only at run time.

## Rules that are easy to get wrong

- **Rule order is behaviour.** Renovate merges every matching `packageRule`; on a conflicting
  property the **last** one wins. Broad grouping first, narrow overrides after.
- `allowedVersions` and `matchUpdateTypes` must not appear in the same package rule.
- `platform` is a global-only option; set `RENOVATE_PLATFORM` in the pipeline instead.
- `baseBranches` was renamed to `baseBranchPatterns`; the strict validator fails on the old name.
- `matchPackageNames` with a bare name is an exact match, not a prefix.
- `prConcurrentLimit` caps simultaneously open pull requests, not per-run creation. There is no
  per-run option; `prHourlyLimit` is the effective one.
- `dotnet-sdk` is a dependency, not a manager. Scope it with `matchDepNames`.
- `recreateWhen: "always"` crashes on Azure DevOps. Never suggest it.

## Pipeline requirements

- **Filter `##vso` out of Renovate's output, unanchored.** Renovate logs file contents at debug
  level and the agent executes those commands, mid-line included:
  `... 2>&1 | ForEach-Object { "$_" -replace '##(?=(vso)?\[)', '# #' }`
- **Install a .NET SDK** if there are .NET projects, or the pull requests arrive without lock files.
- **Windows agents have no bash.** Every step is PowerShell and needs an explicit
  `if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }`.
- **`PowerShell@2` dot-sources the script.** Call the entry point explicitly; a self-invoking guard
  makes the step succeed while doing nothing.
- **Renovate reads config from the default branch.** A feature branch change has no effect. For a
  pre-merge test use `RENOVATE_FORCE` with the complete branch config — see
  [../docs/pre-merge-testing.md](../docs/pre-merge-testing.md).

## Diagnosing a missing or broken pull request

Work through this in order; the symptoms overlap.

| Symptom | Look at |
|---|---|
| Pull request missing, log says `Closed PR #<id> already exists. Skipping branch.` | Abandoned pull request blocking that title. Mostly single-package; some groups (SDK, Bicep, Renovate itself) still run the check |
| Pull request missing, log says `No package files need updating` and no red step | Lock file regeneration. For npm check the artifact log for `EOVERRIDE`, also for packages that are only transitive |
| Pull request present, no lock files, "Artifact update problem" | `NU1109` (split that should be grouped) or `ERESOLVE` (peer dependencies). If the stdout beside the error says `Restored`, it is stderr noise instead |
| Pull request present with a handful of lock files instead of hundreds | One project failed its restore and took the scope with it. Often a transitive requirement colliding with a pin; measure the boundary from the nuspec chain |
| Group pull request recreated but still contains the old content | Its branch survived the abandon and was reused. Delete the branch |
| Hundreds of `TS2345` in the build, paths like `node_modules/a/node_modules/b` | npm nested a second copy because related packages did not land on the same version |
| Renovate step red with `Error closing issue` / `State ... 'Closed'` | A work item titled like one of Renovate's own issues, in a process without a `Closed` state. Rename it |
| Notification step red with `The SSL connection could not be established` | Egress filtering on the agent pool. Move only the notification to another job and pool |
| "New in this run" empty although pull requests were created | The start of the run did not reach the notification; check the logged source |
| Build validation fails with `NU1004` rather than `NU1109` | Lock files are stale, not conflicting: regeneration was discarded |
| Pull request present but nearly empty, log full of `Cannot find replaceString` | A regex `matchString` ending in `\s`, swallowing the CR of a CRLF line ending |
| Statistics exactly doubled | `RENOVATE_CONFIG_FILE` pointed at the repository config |
| An expected package never appears | A pin, or a pin whose bound excludes the current version |
| Nothing at all was created, run green | Ran outside the schedule window |
| Task or Bicep group gone after adding a cooldown, log says `do not have a releaseTimestamp` | `minimumReleaseAge` applied to datasources without timestamps |
| `401` on `pkgs.dev.azure.com` and pull requests without lock files | The build service lacks Packaging Read on the feed |
| Build validation red on `CS0618`/`CS0612`/`CS0672`/`SYSLIB` | A deprecation, not a configuration problem. Pin or scoped `#pragma` |

Full handling for each is in [../docs/working-with-prs.md](../docs/working-with-prs.md).

## Boundaries

- **A failing Renovate pull request is often a code problem, not a configuration problem.** A
  breaking change in a package is fixed in the application, or parked with a pin. Do not reach for a
  configuration change first.
- **Never commit a webhook URL, feed credential or token** into the configuration. Secrets go
  through pipeline variables and `RENOVATE_HOST_RULES`.
- **Every pin needs an exit.** State the reason and the work item that lifts it in `description`, or
  it becomes permanent by accident.

## Installing this skill

Copy this folder into the location your agent tooling expects — for GitHub Copilot that is
`.github/skills/renovate-azure-devops/`. The relative links assume the `docs/` folder of this
playbook sits alongside it; if you copy the skill on its own, either bring `docs/` with it or
replace the links with your own.
