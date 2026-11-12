# Work items per run and per pull request

Optional. `scripts/New-RenovateWorkItems.ps1` creates one work item per pipeline run and one child
item per Renovate pull request, and keeps their states in step with the pull requests.

## Why bother

Renovate opens pull requests outside your normal planning flow. Without work items the effort is
invisible on the board, which in practice means it is invisible in planning, which means it does not
get done. This makes dependency work show up where the rest of the work is, without anyone having to
remember to create anything.

## What it does

| Trigger | Result |
|---|---|
| Every run | One run item in the team's current iteration, created directly in the configured state |
| Each new active Renovate pull request | A child item linked to that pull request |
| A run with no new pull requests | A single placeholder child, "No pull requests created in this run" |
| Pull request merged | Child moves to Done |
| Pull request abandoned | Child moves to Removed on the next run |
| Pull request still open | Nothing; no duplicate child is created |

The placeholder is deliberate. An empty run item with no children is indistinguishable from a step
that never ran.

The Done transition is normally done by Azure DevOps itself through "complete linked work items".
The script does it as well, as a safety net, because that setting is easy to leave off and the items
then stay open forever.

## Configure it for your process

The defaults assume a Scrum process. Adjust these:

| Parameter | Default | Change it when |
|---|---|---|
| `RunWorkItemType` | `Product Backlog Item` | Agile uses `User Story`, Basic uses `Issue` |
| `RunWorkItemState` | `Committed` | Agile uses `Active` |
| `PrWorkItemType` | `Task` | Basic uses `Issue` |
| `ParentWorkItemId` | `0` (no parent) | You want all dependency work under one epic or feature |
| `Team` | the project name | Your team is not the default team |
| `AreaPath` | project default | You want a specific area |
| `BranchPrefix` | `refs/heads/renovate/` | You changed Renovate's `branchPrefix` |
| `ClosedPrLookbackDays` | 14 | Your runs are less frequent than fortnightly |

Azure DevOps accepts a non-default state directly on creation, so no second call is needed.

## Running it

The pipeline step calls it like this:

```yaml
- task: PowerShell@2
  name: governance
  condition: succeededOrFailed()
  inputs:
    targetType: inline
    pwsh: true
    script: |
      . '$(Build.SourcesDirectory)/scripts/New-RenovateWorkItems.ps1'
      Invoke-Main
  env:
    SYSTEM_ACCESSTOKEN: $(System.AccessToken)
```

Two things there are not stylistic. `PowerShell@2` **dot-sources** the script, so the entry point has
to be called explicitly — a self-invoking guard makes the step succeed while doing nothing. And
`succeededOrFailed()` matters because Renovate can create pull requests and then fail; those pull
requests still need tracking.

The `name:` is what makes the run item id usable later. The script publishes it as the output
variable `RenovateRunItemId` (only when an item was actually created), and the notification step
reads it as `$(governance.RenovateRunItemId)`, or through `dependencies` from another job. An output
variable is not mapped into the environment under its plain name, so pass it explicitly through
`env:`.

To see what it would do without writing anything:

```powershell
. ./scripts/New-RenovateWorkItems.ps1
Invoke-Main -WhatIf
```

## Idempotency

The script is safe to run repeatedly. Before creating a child it checks whether the pull request
already has a linked work item, and before changing a state it checks the current one. Items already
in the target state, or in a terminal state, are left alone — so a re-run never resurrects something
you deliberately closed.

A run item is created on **every** run, though, including empty ones. If your board gets noisy,
either set a parent so they collect in one place, or close them in bulk.

## Permissions

The build service needs permission to create and edit work items in the area path the items land
in ("Edit work items in this node" and "View work items in this node" on that area). Check that first
when creating the run item fails. It needs no *Delete work items*: the script only moves items to
Done or Removed, never deletes them.

## Closing the run item

Close the run item yourself once all its children are Done or Removed; the script never touches the
run item after creating it. Its description tells the reviewer exactly that.
