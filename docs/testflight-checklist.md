# TestFlight checklist for msgblast on iPhone

The phone app (`msgblastMobile`, bundle id `com.msgblast.ios`, team
`C4XLZBEPK8`) has only ever been installed from Xcode with a development
certificate. This list takes it to a TestFlight build. Work top to bottom; each
box is a fact to make true, not a step to skim. Items marked **repo** need a
commit; items marked **account** happen in App Store Connect or the developer
portal; items marked **this Mac** are local setup observed on 2026-10-30.

## 1. Accounts and signing

- [ ] **account** An App Store Connect app record exists for `com.msgblast.ios`
  (name "msgblast", primary language English, bundle id registered in the
  developer portal under team `C4XLZBEPK8`). The Mac app's identity is
  `com.msgblast.mac`; the phone app is a separate record.
- [ ] **this Mac** An **Apple Distribution** certificate is installed. As of
  2026-10-30 only two Apple Development certificates exist here (`79C5KNJGL3`
  for `C4XLZBEPK8`, `WBL59H6C9B` for another team), so Xcode cannot archive for
  the store yet. Create it in Xcode › Settings › Accounts › Manage Certificates,
  or let automatic signing create it on the first archive.
- [ ] **this Mac** An App Store Connect API key (`.p8`) with the App Manager role
  is stored at `~/.appstoreconnect/private_keys/` for command-line uploads, or
  the upload is done from Xcode Organizer. Neither exists here yet.
- [ ] **repo** `scripts/generate_project.py` keeps `CODE_SIGN_STYLE=Automatic`
  for `msgblastMobile`; archives pass `DEVELOPMENT_TEAM=C4XLZBEPK8` the way the
  device builds already do. No entitlements file is needed: the app uses the
  Secure Enclave through the default keychain and no shared groups.

## 2. Things the store requires that the project does not declare yet

- [ ] **repo** Add `ITSAppUsesNonExemptEncryption = NO` to
  `msgblastMobile/Info.plist`. The app uses only Apple's CryptoKit and TLS
  (P-256, X25519, ChaChaPoly) for its own pairing channel, which is exempt
  mass-market encryption, so the answer is "no non-exempt encryption". Without
  the key, App Store Connect asks on every build and blocks internal testing
  until answered.
- [ ] **repo** Add a privacy manifest `msgblastMobile/PrivacyInfo.xcprivacy`
  (register it in `generate_project.py` and regenerate). Declare the required
  reason APIs the app touches: `NSPrivacyAccessedAPICategoryUserDefaults`
  (reason `CA92.1`) for app preferences, and
  `NSPrivacyAccessedAPICategoryFileTimestamp` (reason `C617.1`) if the SQLite
  store or attachment cache reads file dates. Declare no tracking and no
  tracking domains. Collected data: none leaves the device except to the
  user's own Mac; declare `NSPrivacyCollectedDataTypes` as empty.
- [ ] **repo** Confirm the marketing version and build for the first upload.
  The project default is `MARKETING_VERSION 0.1.0`, `CURRENT_PROJECT_VERSION
  1`. TestFlight requires each upload of the same version to carry a higher
  build number. Decide now whether builds are bumped by editing
  `generate_project.py` or passed to `xcodebuild` as
  `CURRENT_PROJECT_VERSION=<n>` the way the Mac release workflow does, and
  write the choice into this file.
- [ ] **repo** The app icon is the canonical Icon Composer bundle compiled for
  iOS. Verify the archive's `Assets.car` carries the 1024 pt marketing icon
  (`assetutil --info` on the archived `Assets.car`), since App Store Connect
  rejects a build without it.
- [ ] **repo** Confirm the Debug-only fixture code is compiled out of Release:
  `strings <archive>/Products/Applications/msgblastMobile.app/msgblastMobile |
  grep -c 'MSGBLAST_FIXTURE\|Studio Mac'` must print `0`. This is already part
  of the local verification and must stay part of the archive check.

## 3. Purpose strings and capabilities to re-read before upload

These are present today; read each one as a reviewer would.

- [ ] Camera: "msgblast uses the camera to scan the pairing code shown on your
  Mac and to take photos you send from your Mac."
- [ ] Local Network: "msgblast connects to msgblast on your Mac over your local
  network or Tailscale." Bonjour service `_msgblast._tcp` is declared in
  `NSBonjourServices`; without it iOS blocks discovery silently.
- [ ] Photo Library: "msgblast sends the photos you choose to your Messages
  agents through your Mac."
- [ ] Microphone: "Needed for dictating a message." Speech Recognition: "Turns
  your voice into message text on this phone." Dictation falls back to Apple's
  server recognizer when on-device is unavailable; the app shows a one-time
  note when that happens. Mention it in the beta description.
- [ ] URL scheme `msgblast://` handles pairing links. No background modes, no
  push, no App Groups, no iCloud.
- [ ] Deployment target is iOS 26.0. Testers on iOS 18 or 25 cannot install
  the build; say so in the invitation.

## 4. Build and upload

Run from a clean export of the reviewed commit, never from a tree a builder is
editing (`git archive HEAD | tar -x -C build/export`), as the local previews do.

- [ ] Archive:

  ```sh
  xcodebuild -project msgblast.xcodeproj -scheme msgblastMobile \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath build/msgblastMobile.xcarchive \
    DEVELOPMENT_TEAM=C4XLZBEPK8 CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates archive
  ```

- [ ] Export and upload with an `ExportOptions.plist` whose `method` is
  `app-store-connect`, `destination` is `upload`, `teamID` is `C4XLZBEPK8`,
  and `uploadSymbols` is `true`:

  ```sh
  xcodebuild -exportArchive -archivePath build/msgblastMobile.xcarchive \
    -exportOptionsPlist scripts/ExportOptions-testflight.plist \
    -exportPath build/testflight -allowProvisioningUpdates
  ```

  Commit `scripts/ExportOptions-testflight.plist` once it works. Xcode
  Organizer's Distribute App is the fallback for the first upload.
- [ ] Before uploading, run the same gates as a local reinstall: kit tests
  hosted on macOS, the Mac remote classes, the protocol tests, the Python
  suite, and a device smoke test of pairing, a send, and a reply.
- [ ] After processing, record the build number, the archive's source SHA and
  the dSYM presence in `docs/evidence/` next to the PR evidence for that
  revision.

## 5. TestFlight configuration

- [ ] **account** Export compliance: with `ITSAppUsesNonExemptEncryption = NO`
  in the plist the question is pre-answered; otherwise answer "uses encryption,
  exempt" per build.
- [ ] **account** Test Information: a contact email, and a **Beta App
  Description** that states the hard requirement up front: the app only works
  with msgblast running on a Mac on the same network or Tailscale tailnet, with
  Remote turned on in msgblast › Settings › Remote. Without that, a reviewer
  sees only the pairing screen.
- [ ] **account** **What to Test** for the first build: pair by QR, open a
  group and a direct thread, filter by tapping an agent in the header, send to
  Muse or a website agent, reply from a long-press, rename a group from
  Details, dictation, Photos and Links in Details, lock the Mac and watch the
  subtitle. Say that Messages contacts send real iMessages.
- [ ] **account** Beta App Review (external testers only): because the
  reviewer has no paired Mac, attach a short demo video and notes explaining
  that the app is a controller for a Mac app the tester installs separately;
  provide a Mac the reviewer could pair with only if the team is willing to
  host one, otherwise expect the review to rely on the video. Internal testers
  (up to 100 App Store Connect users) need no review and are the right first
  audience.
- [ ] **account** Create an internal group "msgblast Mac owners" and add only
  people who run msgblast on a Mac. Enable automatic distribution for the
  group so each processed build reaches them.
- [ ] **account** Turn on crash and feedback collection; TestFlight feedback
  screenshots land in App Store Connect, and crash reports complement the
  device `.ips` files already pulled with `devicectl` during development.

## 6. Tester onboarding note (paste into the invitation)

- Install msgblast on your Mac from `https://updates.msgblast.app/latest.zip`
  (or run a Dev preview), open Settings › Remote, turn Remote on, and keep the
  Mac awake or let the phone's Keep Mac Awake do it.
- Put the phone and Mac on the same Wi-Fi or the same Tailscale tailnet. If
  pairing hangs, restart Tailscale on the phone first; a stale MagicSock state
  has blocked pairing before.
- Scan the QR code from the Mac's Remote pane. Check the key fingerprint
  matches. One phone can be paired at a time; pairing a second forgets the
  first.
- Grant Local Network when asked, and Microphone and Speech only if you want
  dictation.

## 7. Before each later TestFlight build

- [ ] The branch is merged to `main` and the archive is built from the merged
  commit, recorded as the source SHA.
- [ ] Build number is higher than the last processed build for that version.
- [ ] Release-note text for testers describes what changed on the phone and
  which Mac version it needs; protocol additions are optional fields and
  actions, so an older Mac must still pair and degrade visibly (initials
  instead of artwork, "Open on your Mac" instead of thumbnails).
- [ ] The phase-3 procedure's live checks still hold on a real phone:
  reconnect after background, locked Mac subtitle, a Mac-app send, a website
  send, a short and a long thread.

## Known limits to disclose to testers

- Dictation needs an on-device speech model for the phone's language or it
  uses Apple's server recognizer, which the app says once.
- The Hark mark is white-backed because the Mac flattens it before export.
- Very long threads (hundreds of messages) lay out as a plain stack and may
  open more slowly; this has not been measured.
- iPhone Mirroring on a Mac cannot drive the microphone or show the keyboard;
  test dictation and the emoji keyboard on the phone itself.
