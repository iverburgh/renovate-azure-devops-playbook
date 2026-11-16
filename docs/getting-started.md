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
| `pipelines/package-guard.yml`, `scripts/Test-PackageHygiene.ps1`, `config/package-hygiene-allowlist.json` | optional; see step 10 |

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

## 9. Optional: a github.com token for release notes

Without a github.com token, Renovate skips release notes for every dependency whose source lives
on GitHub, so those pull requests arrive without changelogs. See
[configuration.md](configuration.md#release-notes-need-a-githubcom-token) for how to add one
without breaking the run.

## 10. Optional: a package guard

With Central Package Management, Renovate keeps every entry in `Directory.Packages.props` current,
used or not. `scripts/Test-PackageHygiene.ps1` fails a pull request on dead entries, orphaned lock
files and unreviewed bypasses of central versions. Attach `pipelines/package-guard.yml` as a second
build validation policy, with the path filter from its header. See
[package-hygiene.md](package-hygiene.md).

## One pipeline per repository, or one for many

The supplied pipeline updates exactly one repository: its own, through `RENOVATE_REPOSITORIES`.
The configuration, the pipeline and the permissions all sit next to the code they govern, and the
[pre-merge test](pre-merge-testing.md) assumes that layout.

If you have many repositories, the other common layout is a central bot repository. It holds a
single pipeline and the global configuration, and Renovate either works through an explicit list of
repositories or finds them itself:

```js
// config.js in the bot repository
module.exports = {
  platform: 'azure',
  autodiscover: true,
  autodiscoverFilter: ['<project>/*'],
};
```

Things to settle before you choose it:

- **Shared rules go in a preset.** Put them in a `default.json` (or a named file such as
  `dotnet.json`) in one repository. Each target repository then needs only
  `{ "extends": ["local><project>/<config-repo>"] }`, or `local><project>/<config-repo>:dotnet` for
  a named file. `local>` resolves presets on the platform Renovate is running against. Renovate has
  deprecated using `renovate.json` as the name of a shared preset file. See
  [shareable config presets](https://docs.renovatebot.com/config-presets/).
- **Onboarding is on by default.** A repository without a config first gets an onboarding pull
  request, and is not updated until that is merged. The `onboarding`, `onboardingConfig` and
  `requireConfig` options control this; see the
  [self-hosted configuration](https://docs.renovatebot.com/self-hosted-configuration/) reference.
- **`autodiscoverFilter` set through an environment variable does not support commas inside a
  filter.** Use a regex filter there, or set the option in `config.js`.
- **The build service needs the four repository permissions from step 3 on every target
  repository**, plus View project-level information. Which identity that is depends on the job
  authorization scope. It is the project-scoped build service unless "Limit job authorization scope
  to current project" is off, in which case it is the collection-scoped one.
- **"Protect access to repositories in YAML pipelines" limits the job token to repositories the
  job references** through a `checkout` step or a `uses` statement. Microsoft enables it by default
  for organizations and projects created after May 2020. Either reference every target repository
  in the pipeline, or accept that the token cannot reach the others. See
  [job access tokens](https://learn.microsoft.com/azure/devops/pipelines/process/access-tokens).
- **One token can then write to every repository**, and one broken run delays them all. That is
  the trade-off for maintaining a single pipeline.

We ran the per-repository layout only, so the playbook's pipelines and scripts assume it.

## Verify locally at any point

```powershell
npx --yes --package renovate@<version> -- renovate-config-validator --strict
npx --yes renovate@<version> --platform=local --onboarding=false --dry-run=full
```

Run both from the repository root, and **without** `RENOVATE_CONFIG_FILE` — setting it loads your
config twice. The local platform only extracts at info level; add `LOG_LEVEL=debug` to see branch
names and proposed versions.
