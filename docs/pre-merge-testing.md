# Testing a config change before you merge it

The hard part is not running Renovate against a branch. The hard part is that **Renovate reads its
repository config from the default branch, always** — so the obvious test does not test what you
think it does.

## Why the obvious approaches fail

| Attempt | What actually happens |
|---|---|
| Run the pipeline on your feature branch | Renovate reads `renovate.json` from the default branch. Your change has no effect |
| Also set `baseBranchPatterns` to your branch | Better, but repository config still comes from the default branch and beats admin config |
| Set `RENOVATE_CONFIG_FILE` to your branch's config | Loads the config **twice** and merges the arrays. Counts double and file edits get dropped |

We worked through all three in that order. Only the fourth is faithful.

## What works: RENOVATE_FORCE

`RENOVATE_FORCE` has the highest priority and **overrides** rather than merges. Push the complete
config of your branch through it, plus the overrides that make a manual daytime run behave:

```pwsh
$force = Get-Content "$env:BUILD_SOURCESDIRECTORY/renovate.json" -Raw | ConvertFrom-Json
$force.baseBranchPatterns = @($branch)
$force.enabled            = $true
$force.schedule           = @()   # otherwise nothing is created outside the window
$force.prConcurrentLimit  = 0     # see the limits caveat below
$force.prHourlyLimit      = 0
$force.packageRules = @([pscustomobject]@{ matchManagers = @($force.enabledManagers); enabled = $true }) + @($force.packageRules)
$env:RENOVATE_FORCE = $force | ConvertTo-Json -Depth 20 -Compress
```

That is what the `baseBranchOverride` parameter in [pipelines/renovate.yml](../pipelines/renovate.yml)
does. The re-enable rule at the front matters: it overrides a manager-level `enabled: false` sitting
on the default branch, which a plain `enabled: true` at repository level does not reach.

Use `managersOverride` alongside it to limit a test run to one manager. That parameter fails fast on
an unknown name on purpose — an empty `enabledManagers` means *all* managers, so a typo would
quietly widen the run instead of narrowing it.

## Two things the harness cannot prove

**Rate limits.** The harness sets both limits to zero so you can see every resulting pull request.
That means a change to those limits is exactly the thing it cannot validate. Check those with
`--print-config` and confirm on the first real scheduled run.

**Anything about the default branch itself.** By construction you are overriding it.

## The cheaper loop: local dry runs

Most config questions do not need a pipeline at all.

```powershell
npx --yes --package renovate@<version> -- renovate-config-validator --strict
npx --yes renovate@<version> --platform=local --onboarding=false --dry-run=full
```

Run from the repository root, without `RENOVATE_CONFIG_FILE`, and note that `--platform=local`
requires `--onboarding=false`.

At info level you get extraction statistics only. Branch names and proposed versions need
`LOG_LEVEL=debug`, and then you grep:

| Looking for | Grep for |
|---|---|
| Which branches would be created | `"branchName"` |
| What a specific package would become | `"depName": "<name>",` and read the nearby `newVersion` |
| Whether a pin took effect | The total at `flattened updates found`, before and after |

Lookup failures against a private feed are normal locally and do not invalidate the result.

## What a good before-and-after looks like

When changing grouping or pins, the evidence worth capturing is a comparison, not a snapshot:

- The set of branch names before and after. For a pin change these should be **identical** —
  `allowedVersions` filters candidate versions and never touches group assignment. If branches move,
  something else changed too.
- The proposed version for the affected package, before and after.
- The total update count, which is the only reliable signal that a pin did anything at all.

## Cleaning up test artefacts

A pre-merge run creates real pull requests, branches and work items. Clean them up, and be aware
that abandoning your own test pull requests **blocks those same titles** in later test runs on that
branch. For a repeatable test, delete the branch without abandoning the pull request.

Work items generally cannot be hard-deleted without elevated permission; setting them to a removed
state is usually the practical option.
