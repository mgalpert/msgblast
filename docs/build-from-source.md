# Build msgblast from source

Use this guide to run your own copy or build a feature. The source repository is
public; the local preview path needs no production release credentials. To share
your change, follow [Contributing](../CONTRIBUTING.md).

## Requirements

| Tool | When it is needed |
| --- | --- |
| Full Xcode 27 with its macOS SDK | Native builds, Icon Composer artwork, and tests; matches the configured CI runner |
| macOS capable of running Xcode 27 | Development host; the built app targets macOS Sequoia 15 or later |
| Apple Silicon Mac | Dev/Demo packaging and CI currently target `arm64` |
| Git | Cloning, branches, and PR revisions; optional for a source ZIP compile |
| Python 3.11 or later | Build helper, preview packaging, project generation, and tooling checks |
| `rg` (ripgrep) | Some optional controller fixture scripts locate Swift sources with it |
| Node.js 22 and npm | Download Worker or feedback checks; unnecessary for native builds |

Install full Xcode and finish its first-launch setup. Command Line Tools alone
do not provide this project's native environment. Check the selected tools:

```sh
xcodebuild -version
xcrun --find swiftc
python3 --version
```

If the active developer directory points to Command Line Tools or another Xcode,
select the actual full-Xcode installation for this shell:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

CI uses `/Applications/Xcode_27.0.app/Contents/Developer`; your app name may differ.
This avoids changing the machine-wide Xcode selection.

## Clone or fork

For personal use:

```sh
git clone https://github.com/mgalpert/msgblast.git
cd msgblast
```

For contributing, fork first and clone your fork using [Contributing](../CONTRIBUTING.md#get-a-working-copy).
A source ZIP has no Git history; use a clone for the preview path's revision
metadata. The compile-only command below can also work from a source ZIP.

## Recommended: separate Dev and Demo apps

Run from the repository root:

```sh
python3 scripts/build_preview_apps.py \
  --sha "$(git rev-parse HEAD)" \
  --run-url "Local build (no Actions run)" \
  --output build/contributor-preview
```

The script copies the working tree to a temporary workspace, selects preview
artwork there, builds both apps, ad-hoc signs them, verifies signatures and
compiled icons, and creates ZIPs plus `preview-manifest.json`. It does not publish,
use Apple credentials, read release secrets, or change the committed green icon.
The first run needs network access for pinned Sparkle and cloudflared assets.
It builds both variants even if you only need Demo.

| App | Icon / bundle ID | Behavior | Saved app state |
| --- | --- | --- | --- |
| `build/contributor-preview/msgblast Dev.app` | Blue-green / `com.msgblast.development` | Live accounts and Messages; production updates disabled | `~/Library/Application Support/msgblast-Dev` |
| `build/contributor-preview/msgblast Demo.app` | Blue / `com.msgblast.demo` | Simulated conversations/accounts; production updates disabled | `~/Library/Application Support/msgblast-Demo` |

Start with Demo:

```sh
open "build/contributor-preview/msgblast Demo.app"
```

It uses sample Cedar, Lumen, and Orbit conversations and does not invoke installed
provider CLIs or send real Messages. Rebuild after changes. Quit a running preview
before rebuilding its output. These bundle IDs and support folders are shared by
other local builds of the same variant; a separate output directory alone does
not create a new state profile.

For live integration work, open Dev when you intend to use real accounts:

```sh
open "build/contributor-preview/msgblast Dev.app"
```

Do not pass `--demo` or `--isolated-demo` to Dev. Its separate state does not make
requests or sends simulated. Use Demo for fixture evidence. Keep the installed
`/Applications/msgblast.app` in place and use the preview's distinct name.

The `--sha` is manifest metadata, not enforcement of a clean tree. While
iterating, the copied workspace includes uncommitted edits. For PR evidence,
commit the intended source, rebuild from that revision, and capture that build.
The local run label above is not an Actions URL. The manifest's 14-day expiry
wording describes Actions retention; local outputs remain until removed.

Ad-hoc previews are not Apple-notarized. A quarantined download may show macOS
first-launch approval or an install gate; follow the app's instructions for that
distinct Dev/Demo file. Neither preview replaces production or uses its Sparkle
feed. See the README for the OS's **Open Anyway** procedure if needed.

## Compile or debug in Xcode

The generated `msgblast.xcodeproj` is committed; cloning needs no generation step.
To check compilation with separate derived data:

```sh
xcodebuild -project msgblast.xcodeproj -scheme msgblast \
  -configuration Debug -derivedDataPath build/contributor-check \
  -destination 'platform=macOS' \
  MSGBLAST_APP_BUNDLE_IDENTIFIER=com.msgblast.contributor-check \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDemo \
  CODE_SIGNING_ALLOWED=NO build
```

This is a compile check. Blue artwork does not enable Demo mode; signing-disabled
output is not the runnable packaged Demo. Use the preview script for runnable apps
with explicit mode and state isolation. Intel Macs can attempt this native-
destination compile path, but the two-app packager currently hardcodes `arm64`.

For debugging, open `msgblast.xcodeproj`, select **msgblast**, and use Debug.
The unmodified scheme uses the production bundle ID and support folder; plain
**Run** can open real app state. For a fixture session, set the app target's
`MSGBLAST_APP_BUNDLE_IDENTIFIER` to `com.msgblast.contributor-debug` locally,
select `AppIconDemo`, and add `--demo` and `--isolated-demo` in **Edit Scheme →
Run → Arguments**. Those arguments create temporary fixture state. Keep personal
settings out of the PR. They do not authorize live sends or production state resets.

An unbundled `swift run` is not the supported GUI setup: Xcode registers the icon,
Info.plist, entitlements, frameworks, resources, and helper.

## Dependencies and generated files

- Xcode resolves **Sparkle 2.10.0**, pinned in the generator and Package.swift.
- The build runs `scripts/bundle_cloudflared.py`, downloads official assets pinned
  in `scripts/cloudflared.json`, checks SHA-256, and embeds the matching executable.
  It caches assets in derived data. No Homebrew cloudflared or running tunnel is
  needed to build; the app starts its helper only for Grok Bot setup.
- Usual app/preview builds use Python's standard library. Installer DMG tooling
  additionally needs `scripts/installer-requirements.txt`; see the release guide.
- After adding/removing Swift files or changing targets, resources, or settings,
  edit `scripts/generate_project.py` as needed and run
  `python3 scripts/generate_project.py`. Review/commit the generated project and
  shared scheme with the source change. See [Architecture](architecture.md).

## Accounts, permissions, and state

Muse, ChatGPT, Claude, Grok, and optional Dots use embedded websites. Sign in
inside the app for live web use. Codex CLI and Claude Code are separate optional
agents enabled in Settings; they use their installed CLI's authentication and
configuration. Neither a CLI nor a provider account is needed to build or use Demo.
See [conversations and reports](personal-agent-reports.md) and [Grok Bot](grokbot.md).

Dev needs its own Full Disk Access for Messages history, Contacts permission for
contact lookup/writes, and Automation permission to send through Messages. Web
and CLI chats do not need Messages access. Grants do not transfer from production,
and ad-hoc rebuilds may require approval again. Follow capability-specific setup;
do not reset system permissions or copy production state to prove a build.

## Test and troubleshoot

Use [Testing](testing.md) for native tests, controller fixtures, backend/tooling
checks, and what CI actually validates.

| Symptom | Next step |
| --- | --- |
| SDK/icon compiler error | Check Xcode version and DEVELOPER_DIR; finish full Xcode 27 setup |
| Sparkle or cloudflared download fails | Check GitHub network access and first failing build step; retain pins and checksum verification |
| Signing-disabled output will not launch | Build packaged previews; compilation does not package/sign a usable app |
| New source/resource missing | Regenerate the project and inspect its diff |
| Dev lacks Messages/Contacts access | Check permissions for that exact Dev bundle |
| Preview shows installation guidance | Install that distinct file as instructed, preserving production |
| Changes are not visible | Quit the old preview, rebuild, and open the exact output path |
| Load/save error after switching versions | Preserve state and snapshots; follow [update recovery](update-recovery.md) rather than deleting state.json |
| UI runner cannot control the app | Record the permission failure and use an authorized isolated Mac; do not report a passing suite |

Releases are a separate maintainer workflow. Building or pushing source does not
publish to the production update feed.
