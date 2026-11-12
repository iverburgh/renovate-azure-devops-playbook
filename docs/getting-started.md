# Getting started

What you need, in order, to get self-hosted Renovate running on Azure DevOps. Expect an afternoon
for the first three steps and rather longer for step 4, which is where the actual decisions are.

## 1. Copy the files in

| From here | To your repository |
|---|---|
| `config/renovate.json` | repository root as `renovate.json` |
| `pipelines/renovate.yml` | wherever you keep pipelines |
| `pipelines/renovate-config-check.yml` | same |
| `pipelines/variables/renovate-version.yml` | keep it next to the pipelines |
| `scripts/*` | optional; see steps 6 and 7 |

Then search for `<` and replace every placeholder: `<org>`, `<feed>`, `<your-pool>`,
`<YOUR-TASK-PREFIX>`. The leak-check script in `tools/` will find them for you if you point it at
your copy.

Two paths inside `renovate.json` assume this layout and need to match yours: the custom manager file
patterns for the version file and for your pipeline YAML.

## 2. Check the prerequisites

- **Node 24 or newer.** Renovate 44+ uses `RegExp.escape`. The pipelines read the version from
  `.nvmrc`, which keeps the agent and the repository in step.
- **A .NET SDK on the agent**, if you have .NET projects. Renovate regenerates `packages.lock.json`
  by shelling out to `dotnet restore`; without an SDK the pull requests arrive without lock files.
- **An agent pool.** The supplied pipelines use `windows-latest`. Anything works, but note that a
  Windows pool has no `bash`, which is why every step here is PowerShell.

## 3. Grant the permissions

The build service identity needs, on the repository: **Contribute**, **Contribute to pull
requests**, **Create branch**, **Read**. At project level: **View project-level information**. On
every private Azure Artifacts feed Renovate looks packages up in: **Packaging Read** (Reader) —
without it, lookups and lock file regeneration fail with `401`. And only if you use the work item
step from step 6: permission to create and edit work items in the target area path.

Nothing more: no delete rights, no *Bypass policies*, no *Force push*. Renovate only proposes changes
through pull requests.

Everything authenticates through `System.AccessToken`. Do not introduce a personal access token —
it will work, and then it will expire on someone's last day.

The commits will show `Renovate Bot` as their author. That is Renovate's own default and not the
identity that matters: every push, pull request and feed lookup is done by the build service, so
that is where permissions go.

The [pitfalls page](pitfalls.md#permissions-and-what-each-missing-one-looks-like) lists what each
missing permission looks like in the log, because the error messages are not obvious. Renovate's own
[Azure DevOps platform page](https://docs.renovatebot.com/modules/platform/azure/) is the reference
for the environment variables used here, and records which features the platform does not support.

## 4. Decide your grouping before you run anything

This is the part worth thinking about, and the part where copying our answer may be wrong for you.

**If you use Central Package Management for .NET, you do not have a choice**: everything NuGet goes
in one pull request. Any split produces `NU1109`. That is explained at length in
[pitfalls](pitfalls.md#central-package-management-forces-every-nuget-update-into-a-single-pull-request),
and it is the single most expensive thing we learned.

Without central pinning you have real freedom, and the reference config shows both styles: npm is
split by level with coupled ecosystems grouped, because npm tolerates it.

Ask yourself, per ecosystem:

- Do the packages have coupled transitive requirements? Then group them.
- Is one broken major acceptable as a blocker for the whole batch? If not, you need pins rather than
  splits.
- How many validation builds does one pull request trigger? Splitting can multiply that instead of
  reducing it — see the Bicep entry in the pitfalls.

## 5. Attach the config-check pipeline as a branch policy

`renovate-config-check.yml` does nothing until you attach it. Add it as a build validation policy on
your default branch, with path filters on `renovate.json`, `renovate.json5`, `config.js` and on the
pipeline variables file holding the pinned Renovate version.

That last filter is easy to forget, and it is exactly the file Renovate's self-update touches.

## 6. Optional: work items

`scripts/New-RenovateWorkItems.ps1` makes dependency work visible on the board. Read
[work-items.md](work-items.md) first — the defaults assume a Scrum process and will need adjusting.

## 7. Optional: notifications

`scripts/Send-RenovateTeamsNotification.ps1` posts one message per run. See
[notifications.md](notifications.md), especially the envelope requirement.

## 8. Test before you merge

Do not let the first real run be your first run. The `baseBranchOverride` parameter exists precisely
because Renovate reads its config from the default branch, which makes ordinary branch testing
useless. See [pre-merge-testing.md](pre-merge-testing.md).

## Verify locally at any point

```powershell
npx --yes --package renovate@<version> -- renovate-config-validator --strict
npx --yes renovate@<version> --platform=local --onboarding=false --dry-run=full
```

Run both from the repository root, and **without** `RENOVATE_CONFIG_FILE` — setting it loads your
config twice. The local platform only extracts at info level; add `LOG_LEVEL=debug` to see branch
names and proposed versions.
