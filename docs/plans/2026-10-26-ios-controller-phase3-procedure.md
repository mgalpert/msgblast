# iOS controller phase 3: live Dev validation procedure

Status: **run on 2026-10-28 and 2026-10-29.** Phase 3 of
[the iOS controller plan](2026-10-24-ios-controller-architecture.md) checks the
phone app against the owner's live **msgblast Dev** Mac over Tailscale with real
agents. Recorded values are in the results table. Steps that were not run say why.
Phase 0 results and the original lock-screen questions are in
[the spike record](2026-10-26-ios-controller-spike.md).

## Ground rules for this run

- Use the blue-green **msgblast Dev Remote** preview built from this branch. Leave the
  installed `/Applications/msgblast.app`, any existing msgblast Dev, and their
  support folders alone.
- Do not pass `--demo` or `--isolated-demo` to Dev. The blue Demo app simulates
  agents and replies; **nothing it shows counts as evidence for this run.**
- No real iMessage sends unless you pick a recipient you own (for example your own
  second number) and turn on Settings → Remote → Send iMessages from the phone for
  that step only. Turn it off again afterwards.
- No Contacts writes, no permission resets, no changes in System Settings beyond
  what Dev already has. If a step would need a new permission, stop and note it.
- Every send uses your own accounts and may use plan usage. Keep prompts short
  ("Reply with OK" unless a step says otherwise).
- Record each step in the table at the end. "Pass" means exactly what the step
  says; anything else is a finding, not a failure of the run.

## What you need

- The Mac with Xcode 27, Tailscale running and signed in.
- An iPhone on iOS 26 or later with Tailscale installed and signed in to the same
  tailnet, Developer Mode on (Settings → Privacy & Security → Developer Mode).
- Before pairing on cellular, Tailscale must be connected on the phone (the VPN
  badge shows in the status bar). Without it the phone cannot reach the Mac, and
  pairing stops after about 15 seconds with "Your Mac could not be reached".
- This branch checked out, and the **msgblast Dev Remote** preview built from it
  (rebuild if the branch moved):
  ```sh
  python3 scripts/build_preview_apps.py --sha "$(git rev-parse HEAD)" \
    --run-url "Local build (no Actions run)" --output build/phase3-preview --variant development-remote
  ```
  This is a separate app from msgblast Dev: bundle ID `com.msgblast.development.remote`,
  saved state in `~/Library/Application Support/msgblast-Dev-Remote`. It shares
  nothing with an existing msgblast Dev, so it starts with no conversations, agent
  sign-ins or permissions. Before the run, grant it Full Disk Access, Contacts and
  Messages Automation yourself, and sign in to the website agents you plan to use.
  That setup is the only System Settings change this run expects.

## Steps

### 1. Install the phone app from Xcode

1. Connect the iPhone by cable (or pair it for wireless debugging) and unlock it.
2. Open `msgblast.xcodeproj`, choose the **msgblastMobile** scheme and your iPhone
   as the destination.
3. In the project editor, for each of **msgblastMobile**, **msgblastMobileKit** and
   **msgblastRemoteProtocol**: Signing & Capabilities → check "Automatically manage
   signing" → Team: your team. If Xcode says `com.msgblast.ios` is taken, change
   the msgblastMobile bundle identifier locally (for example
   `com.<you>.msgblast.ios`).
4. Product → Run. On first launch accept the Local Network prompt. Trust the
   developer profile on the phone if asked (Settings → General → VPN & Device
   Management).
5. **Do not commit** the team or bundle-id change: `git checkout -- msgblast.xcodeproj`
   afterwards, or keep it out of any commit.

Record: iOS version, Xcode version, whether the bundle id had to change.
Pass: the app opens on the "Pair with your Mac" screen.

### 2. Run msgblast Dev Remote with remote control on and pair by QR

1. Unzip or open `build/phase3-preview/msgblast Dev Remote.app` (Open Anyway if
   macOS asks). Its saved state is in `~/Library/Application Support/msgblast-Dev-Remote`.
2. msgblast Dev Remote → Settings → Remote: turn on "Allow a paired phone…".
   Network: Tailscale if available. Keep this Mac awake: on. Send iMessages from
   the phone: **off**.
3. Note the Status line (it lists the addresses the app listens on) and the Mac
   identity line (Secure Enclave expected).
4. Choose **Pair a phone…**. On the phone choose "Scan the pairing code" and scan.
5. Compare the Mac name and the **Key** fingerprint shown on the phone with the
   ones under the QR code on the Mac. Tap Pair only if they match.

Record: listening addresses, identity storage, whether name and fingerprint matched,
time from Pair to the inbox.
Pass: fingerprints match; the phone shows the inbox with your msgblast Dev Remote conversations and
no banner; the Mac pane shows the phone as "Connected now".

### 3. First connection over Tailscale on Wi-Fi, then cellular

1. On Wi-Fi: phone Settings (gear) shows **Route** and **Connect time**.
2. Background the app for a few seconds and bring it back (it reconnects).
3. Turn Wi-Fi **off** on the phone (cellular only, Tailscale still on). Force-quit
   and reopen the app.
4. Then turn Tailscale off on the phone and reopen the app.

Record for each: Route (address that won), Connect time, the banner text.
Pass: Wi-Fi and cellular both connect over a `100.x` address; with Tailscale off
the banner says Reconnecting and nothing else is tried or shown as sent.

### 4. Shared send to a website agent and a Mac app agent, then a private follow-up

1. Phone → compose → pick one website agent you are signed into on the Mac (for
   example Claude · Web) and one Mac app agent (for example ChatGPT · Mac app).
2. Watch the compose bar: "Getting ready…" while the Mac prepares, and "Will open
   ChatGPT on your Mac" if that app is closed.
3. Send "Reply with OK". Watch each agent's chip under your message.
4. In the conversation, choose the website agent's filter and send a private
   follow-up "Reply with OK again".

Expected chips: website agent *Sending on Mac → Sent → Replied*; Mac app agent
*Sending on Mac* (while the app is driven) *→ Replied*; the private follow-up shows
only that agent's chip. Any *Not sent* or *Unconfirmed* chip shows the Mac's reason
below it.
Record: chip sequence per agent, time to Replied, whether the Mac app came to the
front, any reason text.
Pass: both replies arrive on the phone; nothing is sent twice (check the agent's
own chat on the Mac); the Mac's own draft is unchanged.

### 5. Lock-screen matrix (lock only, try nothing else)

1. With the phone connected, lock the Mac (⌃⌘Q). Keep it on power.
2. Watch the phone. Do not send anything.
3. Unlock the Mac.

Record: seconds until the phone banner changed, the exact banner text, whether any
conversation content changed while locked, seconds until it cleared after unlock.
Pass: banner "Disconnected: your Mac is locked" while locked; compose is disabled;
after unlock the banner clears and anything that happened meanwhile appears.

### 6. Display sleep with keep-awake on and off

0. Run `pmset -g assertions` and note any holder other than msgblast. Another app
   can keep the display or the Mac awake by itself and hide the result. For
   example a standalone CuaDriver.app with an agent session holds
   `PreventUserIdleDisplaySleep`; quit it, or record it as a limit, before going on.
1. Keep-awake on (Mac setting) and the phone connected. Check that the phone's
   Settings shows "Mac kept awake: Yes" and that `pmset -g assertions` lists
   "msgblast remote control…" for the msgblast Dev Remote process. Then run
   `pmset displaysleepnow` in Terminal. Wait 5 minutes. Send "Reply with OK" to the
   website agent.
2. Wake the display. In Dev → Settings → Remote turn keep-awake **off**. Put the
   display to sleep again and wait past your Mac's system sleep setting
   (`pmset -g | grep sleep`).
3. Wake the Mac and turn keep-awake back on.

Record: other assertion holders from step 0; the phone's "Mac kept awake" line;
for each, whether the phone stayed connected, whether the send replied,
`pmset -g assertions | grep -i msgblast` output before sleeping.
Pass: with keep-awake on, the phone stays connected and the send replies with the
display asleep; with it off, the phone eventually shows Reconnecting and never shows
a send as Sent that the Mac did not run.

### 7. Long desktop send

1. Close the ChatGPT (or Claude) Mac app.
2. From the phone send it a prompt that takes a while ("Write 300 words about
   tides").
3. Watch the Mac while it runs.

Record: the phone note before sending ("Will open … on your Mac"), how long the chip
stayed at *Sending on Mac*, whether the app took focus or switched Spaces, whether
it interrupted anything you were doing on the Mac, final chip.
Pass: the phone warned before sending; the chip ends at *Replied*, or at
*Unconfirmed* with an Acknowledge or Stop waiting action that works from the phone.

### 8. Forget and re-pair

1. While connected, show a pairing code on the Mac again ("Pair a different
   phone…", confirm), let it expire (2 minutes), and try to pair the phone with
   that expired code. Expected: the phone refuses the code and stays connected to
   the existing pairing.
2. Phone → Settings → Forget this Mac. Expected: the pairing screen; cached
   conversations are gone from the phone.
3. On the Mac pane: Forget the phone, then Pair a phone and pair again by QR.
4. While the phone is still paired, open a new pairing link on the phone (for
   example from the Camera app). Expected: the pairing sheet opens and stays open
   while you compare the name and Key fingerprint; it does not close by itself and
   cannot be swiped away. Tap Cancel: it closes and the existing pairing stays.
5. Open the link again with Tailscale off on the phone (cellular) and tap Pair.
   Expected: after about 15 seconds the sheet still shows, with "Your Mac could not
   be reached…" and the Tailscale hint under Pair. Turn Tailscale on and tap Pair
   again: the sheet closes only once the new Mac's inbox has loaded.

Record: what each step showed on both devices.
Pass: a failed or expired code never breaks the existing pairing; after Forget and
re-pair the inbox fills again.

### 9. Inbox tap check

1. In the inbox, tap each of five different conversations once and go back each
   time. Repeat twice (ten taps).

Record: how many single taps opened the conversation.
Pass: all ten open on the first tap. (In the simulator the first tap sometimes did
not navigate; this checks it on a real device.)

## Findings from the 2026-10-28/29 run

### Mac app agents fail without Accessibility and Screen Recording

Muse refused every send with "App control could not complete this request. Review
msgblast permissions" and, depending on the build, "The app is still updating its
controls. No input was sent." or "Keep one main Muse window open and dismiss any
dialogs before connecting." Cause: the Dev Remote copy had neither grant. Without
Screen Recording, the window list the embedded driver returns has empty titles, so
the one-main-window guard in `DesktopAppConversation.target()` finds no titled Muse
window (with the grant, Muse's windows are titled "Muse" and "Log in"). Without
Accessibility the control read fails. Check it read-only with the app's own helper:
`"<app>/Contents/Helpers/cua-driver" call --socket /tmp/msgblast-cua-*/driver.sock check_permissions`
(and `list_windows '{"pid":<Muse pid>}'`).

### Ad-hoc rebuilds drop those grants

Each ad-hoc build has a cdhash designated requirement, so macOS treats every
rebuild as a new app and silently discards the previous grants. Three same-named
copies (`msgblast Dev Remote.app` in different build folders) also let `open -b`
and System Settings pick the wrong one. What was done: all other Dev and Demo
bundles on the Mac were deleted; the kept preview was re-signed with the Apple
Development identity for team C4XLZBEPK8 (`sign_bundle` from
`scripts/build_preview_apps.py`), which gives an identity-based designated
requirement that keeps grants across rebuilds signed the same way; and
`build_preview_apps.py` now stamps local preview names with the build time
(`--build-stamp`, commit d187f6c). Launch previews by explicit path. Re-signing
is still a manual step after each packager run.

### Launch Services resolved an older copy

Launch Services resolved `open -b com.msgblast.development.remote` to an older
copy (ef4943d) even though a newer build existed; this cost one retest. Same
remedy: one stamped copy, launched by path.

### Port and keep-awake fixes verified live

Immediate relaunch kept port 50530 (ce91b7a). The assertion "msgblast remote
control: a paired phone is connected or a send is running" was held while the
phone was connected (60eb924).

### Known gap, not fixed

A pairing code shown while the Mac is on a temporary port carries that port.

Related phase 3 commits on `ios-controller`: f501452, eefc00b, 9689df4, 090eb67,
0b35159, ef4943d, c04d8a5, 4af78c6, c397e8e (merge of origin/main 08e29ee),
11fe07e, ce91b7a, 60eb924, f6f7ae2, d187f6c.

## Results table

| Step | Recorded values | Pass / finding |
| --- | --- | --- |
| 1 Install | iOS 27.2 on iPhone (`iphone181`), Xcode 27, team C4XLZBEPK8 with automatic Apple Development signing, installed with `xcrun devicectl device install app`; bundle id stayed `com.msgblast.ios` | Pass |
| 2 Pair | First attempt hung on "Pairing…" because the phone's Tailscale reported "MagicSock ReceiveIPv4 not running"; a phone restart cleared it. Mac fingerprint shown under the QR matched the phone. | Pass after phone restart. Finding fixed in f501452 (15 s race deadline, named failure) and eefc00b (unreachable hint under Pair) |
| 3 Wi-Fi / cellular | Wi-Fi over Tailscale: Route 100.68.57.78:50530, Connect time 0.1 s, traffic relayed through DERP sfo (no direct path). Reconnect after backgrounding the phone app: pass. | Partial: Wi-Fi pass; cellular and Tailscale-off not run |
| 4 Sends | Mac app agent (Muse), 2026-10-29: phone sent "Reply with OK", phone showed Sent, Mac pane showed "You: Reply with OK" then "Muse: OK", phone showed Replied with Muse's "OK" and an unlocked composer. About 12 s after the send and before the reply, the phone showed "Muse did not finish a request here. Outgoing message observed in the app. Waiting for its reply." with Acknowledge and a locked composer; it cleared itself when the reply arrived. Website agent: not run (rabbit OS3 not signed in in Dev Remote; the phone relayed the reason text correctly). Private follow-up: not run. | Mac app send pass. Finding: the incomplete notice fires before a slow agent has replied, then self-clears |
| 5 Lock | Phone banner "Disconnected: your Mac is locked", "Last heard now"; TLS session kept; keep-awake assertion held across the lock | Pass. Finding fixed in 60eb924 (setKeepAwake was refused while locked) |
| 6 Display sleep | Standalone `/Applications/CuaDriver.app` holds a `PreventUserIdleDisplaySleep` assertion on this Mac | Not run (confounded by that assertion) |
| 7 Long desktop send | | Not run |
| 8 Forget / re-pair | 8a expired code: "This code expired. Show a new one on your Mac.", sheet stayed open, Cancel kept the existing pairing | Partial: 8a pass; forget-and-re-pair not run |
| 9 Inbox taps | 10 of 10 first taps opened the conversation; Acknowledge from the phone cleared the notice twice | Pass |

Run record: Mac `macbook-pro-34`, macOS 27.2 (Darwin 27.2.0), Apple silicon;
Dev Remote source SHA `f6f7ae22b622fc7a63abcb2ff19a03b1c76b3843` (phone app built
from the same SHA); Dev Remote bundle `com.msgblast.development.remote`, listener
port 50530; Tailscale via Tailscale.app, Mac 100.68.57.78, phone 100.79.250.25,
relay DERP sfo; dates 2026-10-28 and 2026-10-29.
