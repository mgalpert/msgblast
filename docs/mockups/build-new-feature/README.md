# Build a New Feature — design proposal

These images were generated with the built-in imagegen tool on October 9, 2026.
They are proposed UI designs, not app captures or pull request evidence. No app
behavior was implemented when these were generated. The menu background is derived from an older
repository screenshot; background details are illustrative.

## Proposed flow

1. Choose **msgblast → Build a New Feature…**.
2. A separate native window opens with **“Excited to see what you build.”**
3. Optionally describe a feature. The idea appears in a selectable prompt preview.
4. Press **Copy Prompt**, then paste it into a coding agent. The agent helps fork
   the repository, clone it locally, build the feature, and run the user's build.
5. Share a pull request with a description, relevant screenshots, and a playable
   video. Review and release happen separately from using a personal build.

## Screens and states

- [Menu entry](01-menu.png)
- [Invitation window](02-invitation.png)
- [Idea entered and prompt copied](03-copied.png)

Use one reusable invitation window. Copying updates the button to **Copied** and
shows **“Prompt copied. Paste it into your coding agent to get started.”**
Editing the idea resets the copy confirmation. An empty idea keeps the editable
placeholder in the prompt, so a user can describe the feature directly to their
agent. Repository and build-guide links should open in the default browser.

## Documentation foundation

The native implementation now follows this flow in `BuildFeatureView.swift`,
including source download/fork links, a version-aware prompt, and App/Help menu
entries. These generated images remain design references, not implementation
evidence.

Contributor groundwork is now in [Contributing](../../../CONTRIBUTING.md),
[Build from source](../../build-from-source.md), [Architecture](../../architecture.md),
[Testing](../../testing.md), and the expanded [AGENTS.md](../../../AGENTS.md).
The build guide describes separate Dev/Demo identities and profiles, and the
contribution guide includes a complete coding-agent starting prompt. Use those
current instructions when implementing the invitation's copied prompt.

## Details to settle before implementation

- Link the current contribution/build guides and use Demo sample data for screenshots
  and videos.
- Make both paths clear: clone/download for personal use; fork for contributing.
  GitHub sign-in is needed to fork or submit a PR.
- Include the user's idea and the app name in the copied prompt. Installed
  version/build can provide context, but the agent must check the source revision.
- Keep the copied prompt limited to its visible text and optional user-entered
  idea; app conversations, contacts, credentials, and diagnostics are unnecessary.
- PRs should explain the problem, resulting behavior, and validation. Follow the
  repository's current AGENTS.md for evidence sections and revision identifiers.
- Use native keyboard navigation, selectable preview text, accessible control
  labels, scrolling for shorter windows, and readable light/dark appearances.

## Links

- Public repository: https://github.com/mgalpert/msgblast
- Fork page: https://github.com/mgalpert/msgblast/fork
- Build guide: https://github.com/mgalpert/msgblast/blob/main/docs/build-from-source.md

GitHub reported the repository as PUBLIC during this design session.

## Copied prompt shown in the mockup

```text
I'm using msgblast and want to build a new feature.

My idea: [Describe your feature here]

Fork https://github.com/mgalpert/msgblast and clone my fork locally. Read AGENTS.md and the build guide. Implement my idea and help me run my own build.

Use the Demo app with sample data to test and record the feature. Prepare a pull request with a clear description, screenshots, and a short video.
```

The implementation should expand the agent instructions to include current
contribution guidance, building separately from the installed app, relevant
checks, and the complete PR evidence requirements. Keep those technical details
inside the copyable prompt, with concise instructions in the window itself.

Exact image-generation prompts are saved in [prompts.md](prompts.md).
