# Renovate on Azure DevOps — a working playbook

[![CI](https://github.com/iverburgh/renovate-azure-devops-playbook/actions/workflows/ci.yml/badge.svg)](https://github.com/iverburgh/renovate-azure-devops-playbook/actions/workflows/ci.yml)

Self-hosted [Renovate](https://docs.renovatebot.com/) on Azure DevOps Pipelines: working
configuration, working pipelines, and the pitfalls that cost us the most time.

Renovate's own documentation is good, but it is written platform-agnostically. Azure DevOps is a
second-class citizen in that ecosystem — several core features behave differently there or do not
work at all, and almost none of that is written down. This repository is the missing half.

Everything here ran in production on a large .NET monorepo: roughly 290 NuGet lock files across
about 60 pipelines, plus npm, Bicep and Azure DevOps task references. Every claim about behaviour
comes from an actual pipeline run, not from reading the docs. The one exception is the cooldown
(`minimumReleaseAge`): it is configured and explained, but at the time of writing not yet confirmed
by a production run. The docs say so where it matters.

## Start here

| If you want to… | Read |
|---|---|
| Get Renovate running on Azure DevOps at all | [docs/getting-started.md](docs/getting-started.md) |
| Understand every line of the config | [docs/configuration.md](docs/configuration.md) |
| Know what to do with the PRs it opens | [docs/working-with-prs.md](docs/working-with-prs.md) |
| Test a config change before merging it | [docs/pre-merge-testing.md](docs/pre-merge-testing.md) |
| Put dependency work on the board | [docs/work-items.md](docs/work-items.md) |
| Post a run summary to a chat channel | [docs/notifications.md](docs/notifications.md) |
| **Avoid our mistakes** | **[docs/pitfalls.md](docs/pitfalls.md)** |

If you read only one file, read the pitfalls.

## What's in here

```
config/renovate.json     Annotated configuration you can adapt
pipelines/               The scheduled run and the PR config-check gate
scripts/                 Work item governance and Teams notifications (PowerShell + Pester)
docs/                    The reasoning behind all of it
skill/                   The same knowledge packaged for an AI coding agent
tools/                   Checks that keep this repository honest, also run in CI
```

## The short version of what we learned

A handful of findings that are not in Renovate's documentation and cost us multiple failed runs
each. All of them are explained properly in [docs/pitfalls.md](docs/pitfalls.md).

- **Central Package Management forces every NuGet update into a single PR.** With
  `CentralPackageTransitivePinningEnabled`, any split — major vs minor, minor vs patch — produces
  `NU1109` downgrade conflicts, because .NET packages carry tightly coupled transitive
  requirements. We proved this three times before accepting it.
- **Pointing `RENOVATE_CONFIG_FILE` at your own `renovate.json` loads it twice.** Renovate already
  reads that file. Setting the variable loads it *again* as global config and merges the arrays.
  In production this silently dropped file edits from a PR.
- **A closed PR blocks its own recreation, permanently.** On Azure DevOps you cannot rename an
  abandoned PR and there are no dashboard checkboxes, so the usual escapes do not exist.
- **Renovate's debug output can execute pipeline commands.** It logs the contents of matched files;
  if those contain `##vso[...]` logging commands, the agent runs them — mid-line, too.
- **The Dependency Dashboard does not work on Azure DevOps.** It needs issues with interactive
  checkboxes. Turn it off rather than relying on it.

## Adapting this to your repository

Nothing here is drop-in. Every file contains placeholders in angle brackets — `<your-pool>`,
`<org>`, `<feed>` — and the configuration encodes decisions that were right for a .NET monorepo
and may be wrong for you. [docs/getting-started.md](docs/getting-started.md) walks through what
you must change and, more importantly, which decisions you should make yourself.

## Further reading

Renovate's own documentation is good and this playbook does not replace it. Start there, come back
here for the Azure DevOps specifics.

- [Renovate documentation](https://docs.renovatebot.com/) — the reference for every option named in
  `config/renovate.json`.
- [Azure DevOps platform module](https://docs.renovatebot.com/modules/platform/azure/) — the
  platform page, and the place where the supported-feature caveats are recorded.
- [Full config presets](https://docs.renovatebot.com/presets-config/) and
  [group presets](https://docs.renovatebot.com/presets-group/) — worth reading before writing your
  own rules. This playbook deliberately avoids broad presets in favour of explicit rules, but a
  preset may well suit you better.
- [Renovate on Azure DevOps](https://www.youtube.com/watch?v=vhdTByXWvd8) — conference talk by Erik
  Lieben, and [the slides](https://github.com/eriklieben/presentations/blob/main/2024-12-27-dotnet-amsterdam-renovate-azdevops/renovate-azdevops-dep-update.pdf).
  The best end-to-end introduction to this specific combination that we found.

## License

MIT — see [LICENSE](LICENSE).
