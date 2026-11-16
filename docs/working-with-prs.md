# Working with the pull requests

Renovate only ever proposes updates as pull requests; nothing is merged automatically. This page is
organised by situation: find what you are looking at, read what it means, do the thing.

If you also run the [notification step](notifications.md), a message arrives after every run — also
after an empty run and after a failed one — and that message is your starting point.

## Reading the notification

| Section | What is in it |
|---|---|
| **New in this run** | Renovate pull requests created during this run |
| **Still open** | Pull requests from earlier runs awaiting review |
| **Possibly blocked** | Abandoned pull requests preventing Renovate from proposing the same update again |

An empty section reads **none**. A section reading **not determined** means the log was unavailable
for that run, so blockages could not be established — see [situation 8](#8-the-notification-is-missing-or-incomplete).

## Find your situation

| What you see | Go to |
|---|---|
| The run failed | [1](#1-the-run-failed) |
| Run succeeded, every section empty | [2](#2-run-succeeded-no-pull-requests) |
| Run succeeded, pull requests under *New in this run* | [3](#3-run-succeeded-there-are-pull-requests) |
| A pull request has a failing build validation | [4](#4-a-pull-request-has-a-failing-build-validation) |
| Comment says "Artifact update problem" | [5](#5-the-lock-file-was-not-updated) |
| Pull requests under *Still open* | [6](#6-open-pull-requests-from-an-earlier-run) |
| Pull requests under *Possibly blocked* | [7](#7-possibly-blocked-pull-requests) |
| A section reads "not determined", or no message arrived | [8](#8-the-notification-is-missing-or-incomplete) |
| An update breaks your code | [9](#9-an-update-breaks-your-code) |
| The build fails on `CS0618` or another deprecation | [10](#10-the-build-fails-on-a-deprecated-api) |

---

## 1. The run failed

**What it means.** The pipeline ended red. That does **not** mean nothing happened: Renovate creates
branches and pull requests *during* the run, not at the end. We had a failing run that had already
opened six pull requests.

**What to do.**

1. Check the same notification under *New in this run*. Pull requests there are handled normally
   (situation 3).
2. Verify they are **complete**. A pull request from a failed run can be half finished — in the run
   above, one pull request contained a single file instead of thirty-eight. Compare the number of
   changed files against what you would expect.
3. Find and fix the cause of the red run. The Renovate step logs at debug level and runs to tens of
   thousands of lines, so filter before you start reading.

The [work item step](work-items.md) runs on a failed run too, so those pull requests still get
tracked.

## 2. Run succeeded, no pull requests

Usually exactly what it says: no new updates. That is the normal outcome in a quiet week.

It is suspicious when you were expecting a specific update. In that case, in order:

- Look under *Possibly blocked* (situation 7). An earlier abandoned pull request holds back the
  same version.
- Check whether the package is **pinned** in `renovate.json`. If so you deliberately get nothing,
  and the pin's `description` says why.
- A group pull request can go missing silently when lock file regeneration fails. That is not an
  error but a `No package files need updating` in the log — see situation 5.

## 3. Run succeeded, there are pull requests

Per pull request:

1. **Review the diff.** A group pull request is large but uniform; scan for unexpected files.
2. **Approve**, and set auto-complete if your process allows it. Build validation red? Situation 4.
3. **Merge.**

If you do not want a pull request:

| Choice | Consequence |
|---|---|
| **Leave it open** | Stays, and gets updated as soon as a newer version appears |
| **Abandon** | For a **single-package** pull request this blocks the version permanently (situation 7). Most **group** pull requests do return, but **on their old branch, with the old content**. If you want Renovate to rebuild one (after a pin, for example), delete the `renovate/<group>` branch as well |
| **Abandon and pin** | The right choice when the update breaks your code — situation 9 |

Do not let pull requests pile up. Renovate rebases every open branch on every run, which costs CI
capacity.

## 4. A pull request has a failing build validation

**What it means.** The update does not compile, breaks tests, or touches so many files that
something else falls over. This is the most common reason a Renovate pull request sits still.

**What to do.**

1. Establish **where** it fails: a compile error, a test, or a validation step of the pipeline
   itself.
2. **Compile or test failure** means the update contains a breaking change. Small and obvious? Fix
   it in the branch, but read the note in [pitfalls](pitfalls.md#renovate-leaves-a-branch-alone-once-you-commit-to-it)
   first. Larger? Situation 9.
3. **The pipeline itself fails** — a path filter, a task version — and that is infrastructure work,
   not application work.
4. A pull request touching many pipeline files starts nearly every validation build at once. Do not
   schedule that at a busy moment.
5. **The package guard fails** — `[dead-entry]`, `[orphaned-lock-file]` or `[cpm-bypass]`. A
   Renovate pull request changes versions, not which packages exist, so the problem is already on
   the default branch. Fix it there; see [package-hygiene.md](package-hygiene.md).

## 5. The lock file was not updated

**What it means.** Renovate updated the versions but could not regenerate the lock file. The pull
request gets an "Artifact update problem" comment and is missing `packages.lock.json` or
`package-lock.json`. It is **not mergeable**: a locked-mode restore will fail.

| Signal in the log | Cause |
|---|---|
| `NU1109` | NuGet downgrade conflict, from related packages bumping separately. This is why all NuGet belongs in one pull request |
| `ERESOLVE` | npm peer dependency conflict. Two packages from one ecosystem must bump together |
| `EOVERRIDE` | A fixed version in `overrides` conflicts with the new version of a direct dependency |

With npm the pull request can be missing **entirely** rather than broken. See
[pitfalls](pitfalls.md#npm-specifics).

## 6. Open pull requests from an earlier run

Renovate does not duplicate these: it recognises the existing branch and updates it when a newer
version appears. Handle them as situation 3.

If one has been sitting for weeks, ask why:

- **Waiting for review** — schedule it.
- **Build stays red** — situation 4 or 5.
- **Will never be merged** — abandon and pin it (situation 9). A permanently open pull request costs
  CI time on every run through the rebase.

## 7. Possibly blocked pull requests

**What it means.** These are **abandoned** pull requests that stop Renovate from offering the same
update again. Without this section you would only notice when an expected update fails to appear.

The block is unconditional and applies to that exact version. Recreating the branch does not help.
Most group pull requests are not affected, but not all of them: groups such as the SDK, Renovate's own
version and Bicep still run the closed-pull-request check. Those can show up here too.

**If rejecting was intentional**, do nothing. A newer version produces a fresh pull request by
itself. If the rejection is structural, pin the package (situation 9) or it returns every week.

**If you do want that update after all**, there are exactly two working routes: wait for a newer
version, or reactivate the closed pull request. Both are described, with what does *not* work and
why, in [pitfalls](pitfalls.md#a-closed-pull-request-blocks-its-own-recreation-and-you-cannot-unblock-it).

## 8. The notification is missing or incomplete

**A section reads "not determined."** Renovate could not deliver its log file, so blockages are
unknown for that run. The other sections are still accurate. This is information loss, not an
outage.

**No message at all.** The notification step skips itself when the webhook URL is missing, leaving
the pipeline green with a warning. Check, in order: did the pipeline run at all; is the webhook
variable populated; is the receiving flow still enabled and are its runs succeeding.

Remember that a successful call does not prove the message was posted — see
[pitfalls](pitfalls.md#http-202-proves-nothing).

## 9. An update breaks your code

Some updates cannot be merged: a breaking change, or an upstream conflict with another package.
Seeing that pull request again every week costs nothing but time. The routine:

1. **Abandon the pull request.** Unsure whether that is wise? See
   [below](#why-not-just-revert-the-one-version-in-the-branch).
2. **Pin the package** in `renovate.json` with `allowedVersions`, keeping Renovate on the working
   version line.
3. **Create a work item** for the migration and put its identifier in the pin's `description`.
4. When that work item is picked up, the pin is removed in the same change and Renovate offers the
   update again by itself.

```jsonc
{ "description": "Temporary pin, lifted by <work item> (Refit 15 reworked IApiResponse)",
  "matchManagers": ["nuget"], "matchPackageNames": ["Refit"], "allowedVersions": "<9" }
```

The decision then lives in git, is visible in review, and carries its reason. If the blockage is
purely upstream and not yours to solve, name the condition instead of a work item — for example
"lift once typescript-eslint supports TypeScript 7".

Two things to get right, both covered in [pitfalls](pitfalls.md#pins): check the bound against your
manifest so the pin is temporary rather than permanent, and take the real target version from a dry
run because not every breaking change is a major.

### The migration work item

A pin is only temporary if the work item behind it gets done, and it only gets done if someone else
can pick it up without asking you. A structure that works:

- **Goal** — one sentence: which package moves to which version.
- **Problem** — what breaks, with the error and a link to the failing build or pull request.
- **Migration** — what has to change in the code, as far as you know.
- **Points of attention** — coupled packages, other pins that must be lifted together, deadlines.

And testable acceptance criteria, for example:

- The end state is in the code: the package is on the new version.
- There is proof: `dotnet nuget why <package>` shows the expected version, the lock files contain it,
  the stage that used to fail is green.
- Existing behaviour is unchanged.
- `dotnet restore --locked-mode` succeeds, with the regenerated lock files in the same pull request.
- All builds are green.
- **The pin is removed in the same pull request.**

Tell the team the item exists, and say so explicitly when it carries a security fix or a deadline;
otherwise it gets the priority of every other technical-debt item.

### Why not just revert the one version in the branch?

It is tempting: put back only the breaking package and merge the rest, so the other updates do not
have to wait a week. It is usually the more expensive route.

- **Renovate stops maintaining a branch you have touched.** From your first commit the pull request
  counts as modified: no further bumps, no rebases.
- **With NuGet you inherit the lock files.** Reverting one version means regenerating every affected
  lock file yourself, and a partial revert is exactly the situation that produces `NU1109`. For
  smaller groups such as Bicep or pipeline tasks it is a minor edit and can be worth it.

Abandoning costs less than it looks, because most group pull requests return. And you do not
have to wait for the next scheduled run:

1. Put the pin in its own small pull request touching only `renovate.json`, and merge it.
2. Abandon the group pull request **and delete its `renovate/<group>` branch**.
3. Start the Renovate pipeline manually with `baseBranchOverride` set to your default branch.
4. You get a fresh group pull request without the breaking package, with lock files Renovate
   generated itself.

Step 2 is not optional. While the branch exists Renovate reuses it as it is: the log shows
`reuseExistingBranch=true` and `No package files need updating`, and not a single restore runs. Your
pin then never reaches the pull request. Only after the branch is gone does Renovate log
`Branch needs creating` and regenerate everything.

Step 3 genuinely needs that parameter: with `updateNotScheduled: false` a plain manual run outside
the schedule window creates and changes nothing. The parameter forces an empty schedule for that one
run. Either give the other parameters a value or leave them out; Azure Pipelines rejects an explicitly
empty string parameter with `is not a valid String`.

**When committing to a Renovate branch *is* right:** when the fix is in your own code, for example a
small API change to make the update compile. Do it as late as possible and merge promptly.

## 10. The build fails on a deprecated API

**What it means.** An update marked a member you use as obsolete, and your build treats that as an
error. This only happens if you opted in, which we recommend: set the deprecation diagnostics to
`error` in `.editorconfig`, so an obsolete API is caught at the moment it is introduced rather than
when the next major removes it.

```ini
[*.cs]
dotnet_diagnostic.CS0612.severity = error   # obsolete member
dotnet_diagnostic.CS0618.severity = error   # obsolete member with a message
dotnet_diagnostic.CS0672.severity = error   # override of an obsolete member
dotnet_diagnostic.SYSLIB0001.severity = error
# ...one line per SYSLIB obsoletion, up to the last one of your .NET version
```

Add your own forbidden-API analyzer rule if you have one. Two things stay outside this gate and
remain warnings: obsoletions reported under third-party analyzer IDs, and `SYSLIB` numbers newer
than the range you listed. Extend the range when you move framework (see
[configuration](configuration.md#moving-to-the-next-framework-major)).

Renovate has no compiler, so the build is the only signal. And because NuGet updates come as one
group, one deprecation holds back the whole batch.

**What to do.**

1. **Find the member and the package**, and count the usages: how many, and across how many
   components.
2. **Choose a route** with the table below.
3. **Create a follow-up work item** — in both routes. Use the structure from
   [situation 9](#the-migration-work-item).

| Choose A: pin | Choose B: `#pragma` |
|---|---|
| Many usages, or spread across components | A handful of usages in one component |
| The update is not needed now | The update is needed now, for example for a CVE |
| The next version removes the member anyway | A pin would cause `NU1109` |
| | The package belongs to the runtime family, so a pin would also block its security patches |

When in doubt, choose A.

**Route A: pin.** Pin the package below the version that *introduced* the deprecation — that is
often a minor, not the next major (see [pitfalls](pitfalls.md#not-every-breaking-change-is-a-major)).
Put the pin in its own small pull request, then abandon the group pull request, delete its branch and
run manually with `baseBranchOverride`, exactly as described
[above](#why-not-just-revert-the-one-version-in-the-branch). The migration removes the pin in the
same pull request.

**Route B: suppress locally.** Create the work item first. Then wrap only the affected lines:

```csharp
#pragma warning disable CS0618 // Obsolete in <package> <version>; remove in <work item>
var result = client.OldMethod();
#pragma warning restore CS0618
```

Later, `git grep "<work item>"` finds every one of them. The work item's acceptance criterion is that
all of these pragmas are gone.

**Do not** use `NoWarn` in a project file, lower the severity, or add `[SuppressMessage]` or a
`GlobalSuppressions` file. All three switch the gate off for far more than the lines you meant, and
nothing reminds anyone to switch it back on.

A convention that keeps this readable: a pragma **with** a work item identifier is temporary; a
pragma **without** one marks a deliberate, permanent use and should say why.

---

# Reference

## Which pull requests to expect

Renovate bundles updates per **group**. The group name is both the pull request title and the branch
name (`renovate/<group>`). With the [reference configuration](../config/renovate.json):

| Group | Contents | Watch out for |
|---|---|---|
| `nuget` | All NuGet updates together, majors included | Bundling is mandatory under Central Package Management; the pull request carries every affected lock file |
| `npm minor+patch` | All npm minor and patch updates | |
| `mui`, `typescript+eslint`, `vitest`, `playwright` | Coupled npm ecosystems | Offered separately, lock file regeneration fails on peer dependencies, or npm silently nests a second copy |
| other npm majors | One pull request per package | Reviewed one at a time on purpose |
| `bicep` | Azure REST API versions | Stable only; preview versions are left alone |
| `dotnet-sdk` | The SDK in `global.json` | Stays within the current LTS major |
| `node` | The version in `.nvmrc` | A major jump touches your runtime, your browsers and your agents; make it its own piece of work |
| `renovate` | Renovate's own pinned version | On a major jump, check the Node version both pipelines run on |
| `azdo-tasks` | Azure DevOps YAML task versions | Touches many pipeline files and triggers many validation builds at once |

## What happens on the next run

| You left the pull request… | Next run |
|---|---|
| **open** | No duplicate. The branch is reused and updated when a newer version exists |
| **merged** | Done. A merged pull request blocks nothing |
| **abandoned** | That version does not return. Does **not** apply to most group pull requests: they return, on their old branch while it exists |

Renovate adds a "Renovate Ignore Notification" comment on close. To ignore a dependency for good,
put it in `ignoreDeps`.

**Is the branch cleaned up?** Abandoning does not delete the source branch. If the group has no
updates left, the next run prunes the orphaned `renovate/` branch (`pruneStaleBranches`). If it still
has updates, the branch is not orphaned: Renovate reuses it with its old content. A single-package
update stays away because of the closed pull request, not because of the branch.
