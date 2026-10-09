# Stable Developer ID releases

This is an optional maintainer signing migration. Contributors can build the
separate local [Dev/Demo apps](build-from-source.md#recommended-separate-dev-and-demo-apps)
without an Apple Developer account or these production credentials. Source
visibility is independent of app signing. See [Automated releases](automated-releases.md)
for the publishing path and [Updates](updates.md) for local diagnostics.

Use one Apple Developer Program team and a Developer ID Application identity for all future msgblast production releases. An Apple Development certificate or a free Xcode Personal Team is insufficient for Developer ID distribution. The first transition from an ad-hoc build may need permission approval again; permission retention must be checked across the first two Developer ID releases.

The existing `.github/workflows/release-adhoc.yml` workflow supports both signing modes. Its filename remains unchanged so existing release commands keep working. `MSGBLAST_SIGNING_MODE` defaults to `ad-hoc` until migration is explicitly activated. When selected, missing Apple credentials stop a Developer ID release. The publisher also reads the prior release manifest from authenticated R2: after the first Developer ID publication, it refuses any ad-hoc downgrade even if the mode variable is removed. A missing or inconsistent existing manifest stops the release before reserving a counter; only an absent feed is treated as a first release. Deliberate signing-identity migrations require a separate reviewed change.

## Apple account setup

1. Sign in to the intended Apple Developer account and confirm its legal team name, 10-character Team ID, active paid membership, and authority to create Developer ID certificates. Use the same team thereafter.
2. Create a **Developer ID Application** certificate with a CSR whose private key stays on the signing Mac. Download the public certificate, pair it with its private key, and confirm the identity with `security find-identity -v -p codesigning`. Do not revoke other certificates.
3. Export only that signing identity as a password-protected PKCS#12 file. Retain a secure backup outside this repository.
4. Create a dedicated App Store Connect **team** API key with a role permitted to notarize software. Record its Key ID and Issuer ID; download its `.p8` private key once and retain a secure backup. This pipeline uses team-key notarization authentication.
5. Obtain explicit approval before giving the certificate/private key or notarization API key to GitHub Actions. Send secrets through stdin to `gh secret set`, never through command arguments, source files, chat, logs, or PR evidence.

Signing-certificate creation, API-key creation, enrollment purchases and updated Apple agreements may require the account holder's action. Do not infer consent to those steps from merely opening the portal.

## GitHub Actions configuration

Set these repository variables on `mgalpert/msgblast`:

| Variable | Value |
| --- | --- |
| `MSGBLAST_APPLE_TEAM_ID` | Verified Apple team ID |
| `MSGBLAST_DEVELOPER_ID_IDENTITY` | Exact `Developer ID Application: NAME (TEAMID)` identity |
| `MSGBLAST_NOTARY_KEY_ID` | App Store Connect team API Key ID |
| `MSGBLAST_NOTARY_ISSUER_ID` | That key's Issuer ID |

Set these encrypted repository secrets:

| Secret | Value |
| --- | --- |
| `MSGBLAST_DEVELOPER_ID_P12` | Base64 PKCS#12 certificate plus private key, without line breaks |
| `MSGBLAST_DEVELOPER_ID_P12_PASSWORD` | PKCS#12 export password |
| `MSGBLAST_NOTARY_API_KEY` | Contents of the downloaded `.p8` private key |

Keep the existing Sparkle key, public key, R2 credentials, `com.msgblast.mac` bundle ID, update host and installed app path. Do not rotate them as part of this migration.

After the reviewed workflows are on main, run **Verify Developer ID credentials** (`verify-signing.yml`) from main. It imports and cleans the real temporary keychain, signs only a tiny isolated executable, and verifies notarization profile access. It has no R2 or Sparkle signing credentials, never publishes an app, and uploads no credential artifacts.

After that verification succeeds, set `MSGBLAST_SIGNING_MODE=developer-id`. This is the activation step. No new release is triggered by setting it. Use a newly reviewed marketing version and the existing tag protocol for the first signed release; Actions continues allocating its counter from the existing ledger.

## What CI does

`ci_signing.py` installs the certificate into an owner-only temporary runner keychain, verifies the expected identity, validates and stores the notarization profile there, and removes the raw credential import files. It refuses credential installation outside GitHub Actions. Only the release workflow receives these secrets; PR validation and fixture builds remain separate.

`release.py` exports with Developer ID, verifies the signing team and hardened runtime, requires Apple notarization acceptance, staples and validates the app ticket, and checks Gatekeeper before creating the final updater ZIP. The explicit notarization keychain argument keeps CI credentials out of the login keychain. The installer contains that same signed and notarized app; its container keeps the existing Sparkle signature.

The always-run cleanup step restores the previous keychain search list and deletes the temporary signing keychain and credential files. A forced runner termination can require runner-side cleanup. The existing Sparkle private seed cleanup also remains in place.

The publisher preserves immutable archives, signed appcasts, build reservations and anonymous download checks. An Apple signing/notarization failure prevents archive/feed publication. Failed reservations can still leave counter gaps, as before.

## Activation verification

- Review and merge the workflow source before enabling Developer ID mode.
- Verify the first published ZIP has the chosen Developer ID authority and TeamIdentifier, strict valid code signatures, accepted notarization and a valid staple. Verify the signed feed, download redirect, archive hash, bundled version/build and green production icon.
- Test the ad-hoc-to-Developer-ID update while preserving user state. The transition may require Contacts, Full Disk Access and Automation approval again.
- Verify a subsequent Developer-ID-to-Developer-ID update retains those permissions. No simulated keychain test proves real macOS permission retention.

References: [Apple Developer ID](https://developer.apple.com/developer-id/), [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [GitHub macOS certificate installation](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
