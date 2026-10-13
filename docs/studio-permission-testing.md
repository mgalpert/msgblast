# Unattended permission checks on the Studio

Routine integration checks use the persistent Cua Space
`msgblast-analytics-check` hosted by `studio`, not the active desktop. Its Dev app
uses `com.msgblast.development`, the blue-green icon, and `msgblast-Dev` support
data. Production updates and telemetry uploads are disabled in the signed
maintainer preview. Demo remains a separate simulated-data app.

## Stable signed builds

The manual **Build stable signed Dev** workflow reuses the existing Developer ID
identity in a temporary GitHub Actions keychain. It signs nested code and the
outer Dev app, verifies the Apple team and stable designated requirement,
requires Accepted notarization, staples the ticket, and checks Gatekeeper. It
uploads only the preview ZIP and public manifest. No private signing key is
installed on the Studio. It does not reserve production build numbers or publish
to the updater host.

The workflow runs only from the default branch. An optional source SHA must be
a full commit already reachable from that workflow revision on main; unmerged
PR code cannot use the signing credentials. Ordinary PR validation stays
credential-free and its previews remain ad-hoc.

```sh
gh workflow run stable-dev.yml --ref main -f source_revision=REVIEWED_FULL_SHA
gh run list --workflow stable-dev.yml --limit 3
gh run watch RUN_ID --exit-status --interval 30
gh run download RUN_ID --name msgblast-stable-dev-REVIEWED_FULL_SHA --dir /tmp/msgblast-stable-dev
```

Check the run's source, manifest source SHA, artifact SHA-256, signing authority,
Apple team, notarization, and compiled blue-green icon before installing. The
packager also supports explicit `--signing-identity`, `--team-id`, `--keychain`,
and `--notary-profile` options for an authorized maintainer signing machine. It
never silently falls back to ad-hoc signing.

## Provision the persistent Space once

Start the existing Space with `cua spaces start SPACE_ID --json`. A relay attach
failure immediately after boot can require checking its state and retrying the
start. Use Cua's `list_spaces`, `space_bash`, `upload`, and `call_tool` capabilities
to reach the isolated guest. Do not fall back to the Studio host desktop.

Install only at `~/Applications/msgblast Dev.app`. Quit Dev before replacement,
keep any previous binary as a ZIP backup, and preserve its support directory.
Do not leave registered `.app` backups sharing the Dev bundle ID. Confirm the
exact running executable path and a single Dev process after launch.

With explicit permission-setup authorization, use the native OS controls in
this guest to grant Contacts and Messages Automation, plus Full Disk Access
where needed. Use the actual onboarding permission checklist. A permission-only guest needs no connected agent to run the checker: it uses the onboarding contact picker until onboarding is completed. Keep Messages running
for the nonrequesting Automation check. No Apple account, provider login, real
message send, or Contacts write is required. A permission prompt blocked by the
computer-use tool is a concrete setup blocker; do not edit TCC databases or
disable protections to replace that approval.

The Space's disk and grants are retained across stop/start. Keep the same signing
identity, bundle ID, and installation path. The first move from ad-hoc to stable
signing can require fresh grants. A new VM has its own consent state.

## Run without permission clicks

On the authenticated Cua controller:

```sh
python3 scripts/studio_permission_checks.py \
  --space SPACE_ID --source-sha REVIEWED_FULL_SHA \
  --team-id C4XLZBEPK8 --output /tmp/studio-permissions-first.json
```

The check requires an isolated guest hosted by `studio`, verifies the installed
and running Dev identity/source/signature, and checks all three native Settings
rows. Messages access is a fresh read of the protected history file; Automation
uses the app's nonrequesting native status check. A harmless Contacts search
must return an empty success result through the real Contacts API. The query is
restored afterward. Before onboarding is complete, the checker opens the native
Messages setup review and contact picker, then cancels the picker without adding
an agent. It does not bypass the requirement to connect an agent before finishing
onboarding. No messages are sent and no Contacts are written.

Build a second signed preview, quit Dev, replace only its binary at the same
path, and rerun with the prior receipt:

```sh
python3 scripts/studio_permission_checks.py \
  --space SPACE_ID --source-sha REVIEWED_FULL_SHA \
  --team-id C4XLZBEPK8 --previous-receipt /tmp/studio-permissions-first.json \
  --output /tmp/studio-permissions-rebuild.json
```

This requires a different code hash, the same designated requirement, and working
permissions after replacement. A missing grant fails the check; it is never
reported as a simulated pass. Run one GUI controller at a time. Receipts contain
only permission/signature results and the Space screenshot path, not Contacts
or message content.

## Coverage and limits

`scripts/test_app_permissions.sh` covers denied, undecided, changed, and explicit
request states with injected responses. `studio_permission_checks.py` proves
real access and retention in the provisioned VM. Neither proves every clean
machine's first-run permission-dialog interaction or message delivery.

The current Space has no MDM enrollment. For automatically granting permissions
to newly created managed guests, Apple's PPPC profile can authorize Contacts,
Full Disk Access, and the specific Dev-to-Messages AppleEvents relationship.
That requires supported device-management enrollment and profile delivery; a
locally written profile is not proof of installation. See
[Apple PPPC deployment](https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web)
and [stable code identity](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
