# Permissions in Settings

The Permissions table shows the three macOS permissions msgblast uses. Each row explains its benefit, shows the current status, and offers Enable or Open Settings when access is missing. Allowed permissions have a Manage action. Restricted Contacts access cannot be enabled by the app.

| Permission | Status check | Enable or recovery |
| --- | --- | --- |
| Messages access | A fresh one-byte read of the protected Messages database, without reusing a cached database handle. No public macOS Full Disk Access status API exists. A missing file shows Not connected; an unknown failure shows Not checked. | Reuses the existing Full Disk Access guide. The user may need to quit and reopen the app after granting access. |
| Contacts | `CNContactStore.authorizationStatus(for: .contacts)` | Requests access when not determined; denied access opens Privacy & Security → Contacts. Contacts can be enabled independently of Messages access. |
| Sending Messages | `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`, off the main thread, targeting only Messages. | Enable requests consent without sending an Apple event or message. Denied access opens Privacy & Security → Automation. If Messages is not running, Check access launches it and checks without requesting permission. |

Checks refresh when Settings opens and when msgblast becomes active. Viewing Settings never requests a new grant. macOS owns these permissions; the table does not change TCC databases or reset previous decisions.

`bash scripts/test_app_permissions.sh` compiles the production controller with injected native responses and a minimal model substitute. It checks the normal refresh and enable methods, including checks without consent, explicit consent requests, denied recovery, Messages launch failure, changed permissions, and demo isolation. No real OS permission, Contacts store, Messages database, or workspace action is used by this harness. Native CI runs it alongside core regressions.

The isolated demo displays a simulation label and never requests real Contacts or Automation access. Its existing permission-guide and Contacts-access preview arguments allow native UI checks to demonstrate enabling Contacts while Messages access remains unavailable. Live status checks require a native app; fixture results do not establish production permission retention.
