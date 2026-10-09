# msgblast documentation

Start here to build your own feature, understand the app, or maintain its services.
The public source repository is [mgalpert/msgblast](https://github.com/mgalpert/msgblast).

## Build and contribute

| Guide | What it covers |
| --- | --- |
| [Build from source](build-from-source.md) | Tools, cloning, separate Dev/Demo apps, Xcode, dependencies, and troubleshooting |
| [Contributing](../CONTRIBUTING.md) | Personal changes, forks, branches, review, and PR screenshots/video |
| [Architecture](architecture.md) | Source map, data flow, providers, state, and generated files |
| [Testing](testing.md) | Native tests, local fixtures, backend checks, evidence, and CI limits |
| [Agent instructions](../AGENTS.md) | Coding-agent quickstart and maintainer constraints |

For a new feature: build Demo, locate the relevant module, make the change, run
its checks, and capture the result from the revision submitted for review.
Local development does not need production release credentials.

## Using integrations

- [README](../README.md): supported agents, everyday use, and macOS permissions.
- [Website and CLI conversations; comparison reports](personal-agent-reports.md):
  separate accounts, saved sessions, configuration, and report restrictions.
- [Grok Bot](grokbot.md): webhook routines, callback tunnel, credential storage,
  and bundled helper.
- [Update recovery](update-recovery.md): preserving state when an older app cannot
  read state written by a newer one.

## Maintainer operations

These procedures affect production services or distribution. A contributor
building locally does not need to activate them.

- [Automated releases](automated-releases.md): Actions publishing, immutable
  archives, counters, signing modes, and public hosting.
- [Updater and local release preparation](updates.md): Sparkle configuration,
  update fixtures, and direct-script diagnostics.
- [Developer ID signing](developer-id-signing.md): optional Apple signing and
  notarization migration.
- [Cloud agents](cloud-agent.md): Ubuntu checks, native CI, branch previews, and
  the configured Cursor environment.
- [Download Worker](../download/README.md): the fixed latest.zip endpoint.
- [Feedback intake](../feedback/README.md): private reports and storage.

The production landing Worker lives in the owner's separate landing checkout.
This repository contains the download Worker and feedback handler template, but
not the authoritative landing site. Local paths in operational notes identify
that owner's environment; they are not contributor prerequisites.

## Historical records and designs

The [initial plan](../plan.md), [integration findings](integration-findings.md),
[October 2 audit](completion-audit.md), [permission research](onboarding-permissions-research.md),
`plans/`, `evidence/`, and `pr-evidence/` record decisions or observations at their
stated dates and revisions. They are not current setup instructions or proof that
the present branch passes. `mockups/` contains proposed designs; generated images
do not establish implemented behavior.

## Keeping guides current

Update the relevant guide in the same change when commands, tools, providers,
persistent state, or workflows change. Keep runnable commands in the build/testing
guides and link to them elsewhere. Checked-in scripts, workflows, and current
source establish what a command does. Record live observations with their dates
and revisions rather than making permanent claims about the latest version.
