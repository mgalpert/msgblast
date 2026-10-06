# Build msgblast from source

Install **Xcode 27**, matching the release build environment, then clone this repository and build the app:

```sh
git clone https://github.com/mgalpert/msgblast.git
cd msgblast
xcodebuild -project msgblast.xcodeproj -scheme msgblast \
  -derivedDataPath build/from-source -destination 'platform=macOS' build
open build/from-source/Build/Products/Debug/msgblast.app
```

You can also open **msgblast.xcodeproj** in Xcode, select the **msgblast** scheme, and click **Run**.

The current source includes Muse, ChatGPT, Claude, and Grok conversations alongside Messages assistants. These integrations are newer than the current published download. ChatGPT uses an installed Codex CLI and Claude uses Claude Code; Muse and Grok use embedded browser sign-in. See [account setup and conversation details](personal-agent-reports.md#native-chatgpt-and-claude-conversations).
