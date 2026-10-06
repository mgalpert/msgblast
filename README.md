# msgblast

msgblast is a Mac app for comparing AI agents in Messages and embedded Muse, ChatGPT, Claude, and Grok chats. Send one prompt to selected agents, read replies side by side, send follow-ups, and reopen saved comparisons. Messages agents also support photos and files.

Requires **macOS Sequoia (15) or later**. Web agents use your existing service accounts. Messages agents require existing one-to-one iMessage conversations.

## Download and install

[Download msgblast for Mac](https://updates.msgblast.app/latest.zip)

Unzip the download, drag **msgblast.app** into **Applications**, and open it.

### If macOS blocks the first launch

After trying to open msgblast, open **System Settings → Privacy & Security**, scroll to the security section, and select **Open Anyway**. Confirm **Open** when macOS asks again, if you trust the download. [Apple's first-launch instructions](https://support.apple.com/en-us/102445#openanyway).

<img src="docs/evidence/readme-onboarding/02-open-anyway.png" alt="macOS Privacy & Security showing that msgblast was blocked, with the Open Anyway button highlighted" width="820">

## Get started

### 1. Allow access to Messages history

Click **Open Settings** in msgblast's Messages history banner.

<img src="docs/evidence/readme-onboarding/01-history-access.png" alt="Actual msgblast history-access screen with the Open Settings button" width="820">

In **System Settings → Privacy & Security → Full Disk Access**, click **+**, choose **msgblast.app** from **Applications**, and click **Open**. Enable its switch and authenticate if requested. You can also drag the app card into that list. [Apple's Full Disk Access instructions](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac).

Quit and reopen msgblast, then click **Check again** if the history banner remains.


### 2. Allow Contacts and Messages Automation

Allow Contacts when msgblast asks, so it can find and save agent contacts. If you previously declined, open **System Settings → Privacy & Security → Contacts** and enable access for msgblast. [Apple's privacy settings guide](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac).

On your first send, allow msgblast to control **Messages**. If you previously declined, open **System Settings → Privacy & Security → Automation**, expand msgblast, and enable **Messages**. [Apple's Automation instructions](https://support.apple.com/en-nz/guide/mac-help/mchl108e1718/mac).

### 3. Add agents and send a prompt

Find agents in **Discover**, or click **Add Agent** to search by name, email or phone number. Start a one-to-one conversation with the agent in Messages first if it does not have one yet.

<img src="docs/evidence/readme-onboarding/03-add-agents.png" alt="Actual msgblast Add agent screen with sample contacts" width="680">

Select your agents, write a prompt, and press the send arrow. Their replies appear together for comparison.

*These are actual app screenshots captured with demo contacts and a simulated history-access prompt.*

Check for new versions from **msgblast → Check for Updates**.

## Comparison reports

Click **Summarize** in a comparison to open a report with a recommended next action, a comparison of the replies, and open questions. Reports use an installed personal-agent CLI and its existing account. See [personal agent reports](docs/personal-agent-reports.md) for setup, supported CLIs, privacy limits, and fixture validation.

## Build it yourself

Install **Xcode 16.4 or later**, then clone this repository and build the app:

```sh
git clone https://github.com/mgalpert/msgblast.git
cd msgblast
xcodebuild -project msgblast.xcodeproj -scheme msgblast \
  -derivedDataPath build/from-source -destination 'platform=macOS' build
open build/from-source/Build/Products/Debug/msgblast.app
```

You can also open **msgblast.xcodeproj** in Xcode, select the **msgblast** scheme, and click **Run**.

## License

Copyright (C) 2026 Michael Galpert and contributors.

Except where separately licensed or attributed, msgblast is licensed under the
[GNU General Public License, version 3 only](LICENSE) (`GPL-3.0-only`). You may
use, modify, and redistribute it, including commercially, under those terms.
Distributed modified versions must remain under GPLv3 and include the
corresponding source as required by the license. The software comes without
any warranty.

Third-party dependencies, service icons, logos, and other attributed assets
retain their respective licenses and rights; this license does not relicense
third-party material or grant trademark rights.
