# Grok Bot in msgblast

For contributor setup and checks, use [Build from source](build-from-source.md)
and [Testing](testing.md). Demo uses simulated Bot replies and does not start a
live tunnel or connect a real routine. Building the app does not require a Bot
account; live connection and requests follow the user's explicit setup.

Grok Bot is a separate optional agent from Grok's website. Its implementation lives in this repository. It sends directly from the Mac to a native Grok Bot webhook and receives the answer on the Mac through an app-managed temporary Cloudflare tunnel. There is no deployed Worker, hosted database, Tincan relay, Cloudflare account, domain or hosting subscription to manage.

## Connect once

1. Choose **Grok Bot** during onboarding, or open **msgblast → Settings → Grok Bot**. Read the visible routine prompt and choose **Copy prompt**. Paste it into the particular Grok Bot you want to connect. This creates a webhook routine that receives the request and POSTs its answer back to msgblast.
2. In Grok Bot, click **msgblast** next to **Created routine** in its reply to open the routine panel. Copy **POST to** into msgblast's **Webhook URL**, and **key** into **Webhook key**. Paste only the key; msgblast adds the Authorization header automatically. Choose **Connect Grok Bot**. Setup never requests your Mac login password. Normal app state contains no webhook key or callback token.
3. Select **Grok Bot** in Agents and send a shared prompt or a message in its native pane. Its answer appears in the same comparison. Each follow-up includes that comparison's local history.

The open-source [cloudflared helper](https://github.com/cloudflare/cloudflared) is included in the app. There is no Homebrew installation or separate tunnel command to run.

Connecting can take up to 90 seconds while the temporary address becomes reachable. An explicit webhook rejection keeps the request unsent and its draft intact; an unknown network result is not automatically retried.

Settings distinguishes **Reading saved key**, **Starting reply tunnel**, and **Saving key**. Secure-storage operations run in the background, prohibit interactive authentication, and wait at most 15 seconds. On Macs with a Secure Enclave, the app remembers the connection in an encrypted local vault across relaunches and ad-hoc rebuilds. The actual private key stays in the Secure Enclave; the file contains ciphertext and an opaque hardware-wrapped key representation. No plaintext credential or unwrapped private key is written, and no permissive Keychain ACL is used. On hardware without a Secure Enclave, the noninteractive data-protection Keychain is used when the app has the required signing entitlements. If neither backend is available, Settings explicitly labels the connection as lasting only until quit.

Legacy file-based Keychain entries are left untouched and are not read. Existing users may need to enter their webhook details once after this change; the old entry is not deleted and no login-password or access-approval dialog is shown.

The routine's URL and key belong to a routine, not the generic xAI model API. A successful webhook acknowledgement means the routine was accepted; it does not contain its answer. The callback instructions are necessary.

## What runs and what is stored

The app opens an HTTP listener on a random port bound only to `127.0.0.1`. It launches cloudflared with a private, empty temporary configuration, the loopback origin and info-level logging. It does not read or change existing tunnel configuration or enable a system service. The helper establishes a temporary HTTPS `trycloudflare.com` address. Only authenticated JSON POSTs to `/reply/REQUEST_ID` are accepted; the listener serves no files, chat history, credentials or management API.

Each request gets a random 256-bit callback credential. Grok Bot receives it in the webhook payload and uses it in the callback's Authorization header. The app stores only its SHA-256 hash with the saved request ID. Responses are matched to the original comparison, saved locally before acknowledgement, and identical callback retries do not append a second answer. Prompt/history and reply bodies are capped at 128 KiB. The credential vault uses ephemeral P-256 key agreement, HKDF-SHA256 and AES-GCM. Its directory is owner-only (0700), its atomically replaced file is owner-only (0600), reads are bounded to 32 KiB, and symlinked or publicly readable files are rejected. Authenticated encryption binds the contents to the app bundle identifier and profile path. The vault is tied to this Mac; moving to another Mac requires entering the routine key again. This protects saved data and does not isolate it from malicious software already running as the same local user. When neither secure backend is available, session-only credentials remain in memory until quit.

Cloudflare relays the callback traffic, so this is not an end-to-end encrypted private connection between Grok Bot and the Mac. Request/reply processing and storage are in the app's inspectable Swift code; cloudflared is open source, while Cloudflare operates the relay network. The outbound prompt goes directly to Grok Bot.

## Bundled helper

Every Xcode app build downloads the official release pinned in `scripts/cloudflared.json`, verifies its SHA-256, and embeds the executable in `Contents/Helpers/cloudflared`. Downloads are cached in the target's derived build directory and checked again on reuse. The helper matches the app's architecture; universal builds combine the arm64 and x86_64 executables. It is signed with hardened runtime before the outer app is signed. Its version and source revision are included in `Contents/Resources/cloudflared.json`.

The app always uses its bundled copy, disables cloudflared's self-update, and starts it only when Grok Bot is connected. Helper upgrades go through the normal app update process. It does not use or change a Homebrew copy, existing tunnels, or launch services.

`CloudflaredNotices.txt` in the app's Resources contains the upstream Apache 2.0 license, Go runtime license, and dependency notices. Dependency notices were collected from the pinned source with `github.com/google/go-licenses/v2@v2.0.1 save ./cmd/cloudflared` for both Darwin architectures. To upgrade, update the pinned version/source/asset checksums, refresh those notices, and verify the packaged helper on each supported architecture.

## Availability and incomplete work

Keep msgblast open and the Mac awake until the reply arrives. [Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/) have no uptime guarantee, use a new hostname on each start, and are documented for testing/development rather than production availability. This integration uses them for personal, best-effort callbacks; it is not an always-on agent service.

The app stops its helper and listener on normal quit. Quitting, disconnecting, or losing the helper ends the callback address and marks waiting requests unconfirmed. Existing requests are never automatically sent again. The Bot also posts its answer in its own chat, so you can inspect a result there if callback delivery fails. **Stop waiting for this reply** lets you explicitly continue; it does not cancel Grok Bot's remote work. A late answer cannot replace an unrelated request.

## Implementation and validation

- `msgblast/Core/GrokBotService.swift`: bounded JSON payloads, direct webhook submission and silent credential storage.
- `msgblast/Core/GrokBotCredentialVault.swift`: hardware-backed encryption and private atomic credential files.
- `msgblast/Core/GrokBotCallbackReceiver.swift`: loopback HTTP receiver, per-request authentication and callback deduplication.
- `msgblast/Core/GrokBotTunnel.swift`: temporary helper process and lifecycle.
- `msgblast/Core/WebAgentSession.swift`: comparison history, request receipts and native replies.

Core tests exercise the actual local HTTP receiver and an intercepted HTTPS webhook transport. The native demo uses simulated callbacks with no tunnel, live Bot, messages or Contacts writes. A live account's routine and callback behavior still require a deliberate end-to-end check after setup.

The feedback intake schema recognizes the `grokbot` provider. Future diagnostic
schema changes need matching validation in `feedback/worker.mjs` and the
authoritative landing Worker; updating this checkout alone does not deploy that
handler. See [feedback operations](../feedback/README.md).
