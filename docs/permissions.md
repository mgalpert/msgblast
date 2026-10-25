# Permissions in Settings

Settings → Permissions and onboarding share the same five permission switches and drag-to-System Settings guides. Switches are red when access is off and green when granted. macOS owns the grants: turning an enabled switch off opens its system setting rather than pretending access was revoked. Restricted Contacts access cannot be enabled by the app.

| Permission | Status check | Enable or recovery |
| --- | --- | --- |
| Full Disk Access | A fresh one-byte read of the protected Messages database, without reusing a cached database handle. No public macOS Full Disk Access status API exists. A missing file shows Not connected; an unknown failure shows Not checked. | Reuses the existing Full Disk Access guide. The user may need to quit and reopen the app after granting access. |
| Contacts | `CNContactStore.authorizationStatus(for: .contacts)` | Requests access when not determined; denied access opens Privacy & Security → Contacts. Contacts can be enabled independently of Messages access. |
| Automation | `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`, off the main thread, targeting only Messages. | Enable requests consent without sending an Apple event or message. Denied access opens Privacy & Security → Automation. If Messages is not running, enabling Automation opens it before requesting consent. |
| Device Control and Data Access (Accessibility on older macOS) | `AXIsProcessTrusted`, without prompting. | Uses the same msgblast app drag guide as onboarding. No separate CuaDriver permission is required. |
| Screen Recording | `CGPreflightScreenCaptureAccess`, without prompting. | Uses the msgblast app drag guide for Screen Recording. The embedded app-control helper must be present. |


Checks refresh when Settings opens and when msgblast becomes active. Viewing Settings never requests a new grant. macOS owns these permissions; the switches do not change TCC databases or reset previous decisions.

`bash scripts/test_app_permissions.sh` compiles the production controller with injected native responses and a minimal model substitute. It checks the normal refresh and enable methods, including checks without consent, explicit consent requests, denied recovery, Messages launch failure, changed permissions, and demo isolation. No real OS permission, Contacts store, Messages database, or workspace action is used by this harness. Native CI runs it alongside core regressions.

The isolated demo displays a simulation label and never requests real Contacts or Automation access. Its existing permission-guide and Contacts-access preview arguments allow native UI checks to demonstrate enabling Contacts while Messages access remains unavailable. Live status checks require a native app; fixture results do not establish production permission retention.

## App setup after onboarding

Settings → App Agents lists each native agent with its installation status, an on/off switch and **Set up**. Missing apps have an **Install** link and cannot be enabled. Gemini remains unavailable in this build; its saved settings are preserved.

Enable Device Control and Data Access and Screen Recording, turn on an installed app, then choose **Set up → Connect**. This uses the same connection flow as onboarding, opens a closed app when needed, and never sends a test message. Grok Bot’s setup includes its bot picker. Connecting does not select the app as a message recipient.

Settings changes save the current workspace before handing off to System Settings. They preserve onboarding progress, conversations and drafts; completed users do not have to repeat onboarding to add another app. After Full Disk Access changes, **Restart & check access** reopens msgblast with that workspace intact.
