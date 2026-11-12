# Run notifications

One message per run, posted to a chat channel. Including for a run that produced nothing, and
including for a run that failed.

That last part is the design decision worth defending. Silence is ambiguous: a quiet week and a
broken notification step look exactly the same. With the Dependency Dashboard unavailable on Azure
DevOps, this message is the only per-run overview there is.

## What the message contains

A heading with the run status, a link to the build and a link to the run work item, then three
sections:

| Section | Contents |
|---|---|
| New in this run | Active pull requests created at or after the run start time |
| Still open | The remaining active Renovate pull requests |
| Possibly blocked | Branches Renovate skipped because a closed pull request with the same title exists |

An empty section says `none`. A section can also say `not determined`, which is deliberately
different: it means the log was unavailable, so blockages could not be established. Reporting
"nothing is blocked" when you do not know would be worse than admitting it.

## Setting up the receiving end

In Microsoft Teams, create a Workflow (Power Automate) from the template **"Post to a channel when a
webhook request is received"**. It gives you a URL.

### The URL is the secret

The URL carries its own signature in the `sig` query parameter. Anyone who holds it can post into your
channel; no other credential is involved. Handle it accordingly:

- **Keep it out of the repository.** Store it as a secret in a variable group (lock switched on) and
  reference the group from the pipeline. Once saved, the value cannot be read back, not even through
  the API, and it appears in logs as `***`.
- **Authorise the group for the pipeline.** Forgetting this does not fail when you save; it fails at
  run time.
- **Pass it explicitly.** Azure DevOps does not map secret variables into a step's environment.
  The reference pipeline does it with
  `env: RENOVATE_NOTIFICATION_WEBHOOK_URL: $(RenovateNotificationWebhookUrl)`.
- **Use the runtime macro** `$(...)`, not `${{ variables.... }}`: variable group values do not exist
  at template compile time.

When the variable is missing or unresolved, the notification step skips itself with a warning and the
run stays green — see situation 8 in [working with pull requests](working-with-prs.md#8-the-notification-is-missing-or-incomplete).

**Rotating** needs no commit: create a new trigger URL for the flow, overwrite the secret in the
variable group, start the Renovate pipeline manually and check that exactly one message arrives, then
disable the old trigger. If the URL was ever committed, rotate it: moving a secret out of the
repository does not remove it from the git history, and the old URL keeps working until you do.

**Guard against regressions** with a blocking pull request check that scans your variable files for
values carrying a signature or a flow invoke path. Report file, key and line number, never the value
itself, and allow no exceptions.

The same pattern fits every pipeline secret: a secret in a variable group, an authorised pipeline,
and an explicit `env:` mapping. Secrets that an application needs at run time belong in a key vault
instead.

### The envelope is not optional

The trigger iterates over `body.attachments` and posts `@item()?['content']` per attachment. A bare
Adaptive Card makes the flow fail on a null array:

```json
{
  "type": "message",
  "attachments": [
    {
      "contentType": "application/vnd.microsoft.card.adaptive",
      "contentUrl": null,
      "content": { "type": "AdaptiveCard", "version": "1.4", "body": [] }
    }
  ]
}
```

Always exactly one attachment.

### 202 does not mean it worked

The trigger accepts asynchronously. It returns 202 whether or not the flow subsequently succeeds, so
the status code tells you nothing about whether a message appeared. The `x-ms-workflow-run-id`
response header gives you the run id; check the run itself.

We spent a round of debugging on this by treating a 202 as proof.

### A failed post fails the step

That is a deliberate choice, and we arrived at it the hard way. The first version logged a warning
and left the run green, on the reasoning that a notification is not worth turning a green run red.
The result was a run that reported success while no message was ever delivered, and nobody noticed
until someone went looking for the message days later.

Since this message is the only per-run overview once the Dependency Dashboard is off, a silent
failure is worse than a red step. The error also carries the full exception chain: the outer layer
of a failed HTTPS call is usually just "see inner exception", while the reason that actually tells
you what to fix — an untrusted certificate versus a blocked host — sits further in.

Worth knowing before you deploy this: a build agent may well have no outbound route to your chat
platform's endpoint, even when everything else it talks to works fine. Test from the agent, not from
your laptop.

## Wiring it into the pipeline

Two pieces, both in [pipelines/renovate.yml](../pipelines/renovate.yml).

**Capture the log.** The blocked-branch detection reads Renovate's own output:

```powershell
npx --yes renovate@$(RenovateVersion) 2>&1 |
  ForEach-Object { "$_" -replace '##(?=(vso)?\[)', '# #' } |
  Tee-Object -FilePath "$env:AGENT_TEMPDIRECTORY/renovate.log"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

`Tee-Object` preserves `$LASTEXITCODE`, so the check below it still works. The `##vso` filter is not
optional — see [pitfalls](pitfalls.md#renovates-own-output-can-execute-pipeline-commands).

**Send on `always()`**, not `succeededOrFailed()`. The preceding work item step can itself stumble,
and this is the step that tells people a run happened at all.

**Record the start of the run yourself.** "New in this run" means: created at or after the moment the
run started. The reference pipeline writes that moment as an ISO 8601 UTC timestamp in a step just
before Renovate runs, and hands it to the notification as `RENOVATE_RUN_START_TIME`.
`System.PipelineStartTime` is the fallback, and a fragile one: a value without an offset is read as
UTC (two hours late in Central European summer time), and a culture-specific format such as
`29-9-2026 02:01:25` is unreadable. Either way the script falls back to *now*, everything lands under
"still open", and nothing errors. The step log says which source it used; `source: renovate job` is the
normal outcome and `unknown` means the hand-over is broken.

## When the agent pool may not reach the flow

Corporate build pools often filter outbound traffic by host name. The symptom is unambiguous once you
know it:

```text
[HttpRequestException] The SSL connection could not be established, see inner exception.
  -> [IOException] Received an unexpected EOF or 0 bytes from the transport stream.
```

DNS resolves, TCP port 443 opens, and the TLS handshake is cut off as soon as the host name appears in
the client hello. That is network filtering, not a permission problem: the flow URL carries its own
signature, and the pipeline identity plays no part. Before asking for a firewall change, prove it with a
throwaway step that, per host, resolves DNS, opens a `TcpClient` to port 443 and runs
`SslStream.AuthenticateAsClient`, logging the certificate issuer. Include a few hosts that you know work
(your package registries) as a control. Log only the host name of the flow, never the full URL.

Posting directly to Teams is not a way around it: Microsoft switched off the Office 365 connectors
(the classic incoming webhook) in May 2026. Microsoft Graph works, but needs an app registration with
`ChannelMessage.Send`, which is exactly the permission work you were trying to avoid.

The pragmatic fix is to keep the Renovate run where it is and move **only the notification** to a job
on a pool that may reach the flow:

```yaml
- job: notify
  dependsOn: renovate
  condition: always()
  pool: <pool-that-may-reach-the-flow>
  variables:
    renovateJobResult: $[ dependencies.renovate.result ]
    renovateRunItemId: $[ dependencies.renovate.outputs['governance.RenovateRunItemId'] ]
    renovateRunStartTime: $[ dependencies.renovate.outputs['runstart.RenovateRunStartTime'] ]
```

In the notification step, map them into the environment the scripts read:
`RENOVATE_RUN_STATUS: $(renovateJobResult)`, `RENOVATERUNITEMID: $(renovateRunItemId)` and
`RENOVATE_RUN_START_TIME: $(renovateRunStartTime)`.

A second job runs on another agent and sees nothing of the first. Four values have to cross the
boundary explicitly, and every one of them fails **silently** when you forget it — the message is
simply wrong:

| Value | Without a hand-over | Hand it over with |
|---|---|---|
| Renovate's log | "Possibly blocked" says *undetermined* | A pipeline artifact. Publish it on `always()`, and publish an empty file when the log is missing, so the publish step itself cannot fail |
| The run result | Every message says *succeeded*, because `Agent.JobStatus` now describes the notification job | `$[ dependencies.renovate.result ]` into `RENOVATE_RUN_STATUS` |
| The work item id | The message loses its link to the run work item | `task.setvariable` with `isOutput=true`, and a `name:` on the step that sets it |
| The start of the run | "New in this run" stays empty | The same output-variable route, from the step that records the timestamp |

One more thing to check on such a pool: it may not have PowerShell 7. Run the step with
`pwsh: false` and make sure the scripts work under Windows PowerShell 5.1. Differences that mattered for
us: `Invoke-RestMethod` returns ISO dates as strings instead of `DateTime`, `System.Net.Http` is not
loaded by default, and `Tee-Object -FilePath` writes UTF-16. Run the Pester suite under both editions.

## Why blocked branches come from the log

The obvious alternative — look at pull request status, or filter out group branches on the
assumption they always recreate — does not hold. `recreateClosed` is not uniformly true for grouped
branches; we measured a run where three group branches from our own configuration ran *with*
"recreating closed PRs is disabled". Filtering on group names would have hidden real blockages.

So the report parses this line:

```
DEBUG: Closed PR #1234 already exists. Skipping branch. (repository=..., baseBranch=main, branch=renovate/foo)
```

Two details that cost us time. The pull request number is in the line itself, which is why a
blockage stays clickable even when the pull request closed before the lookback window. And the
context contains both `baseBranch=` and `branch=`, while PowerShell's `-match` is case-insensitive —
so a naive `branch=` pattern reads the base branch. Hence `(?<![A-Za-z])branch=`.

## Adapting it

`Send-RenovateTeamsNotification.ps1` builds and posts; `New-RenovateTeamsReport.ps1` holds the pure
report and card construction with no network calls at all, which is why it has thorough tests.

For a different chat platform, replace `ConvertTo-RenovateTeamsMessage` with your own envelope and
adjust the POST. Everything upstream of it is platform-neutral.

To add a footer linking to your own runbook, pass `-HelpUrl` and `-HelpLinkLabel` to
`ConvertTo-RenovateAdaptiveCard`. Left empty, the footer is omitted entirely rather than rendering a
dead link.
