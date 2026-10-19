# Desktop app conversations

Muse App, Grok Bot App, and Wabi are optional agents with msgblast's native
conversation pane. They use an independently installed `cua-driver` command.
The existing Muse website, Grok Bot webhook, and CLI agents retain their own
accounts, state files, histories, and execution paths.

## Setup

1. Install cua-driver using its official instructions and grant its required
   macOS Accessibility permission. msgblast does not install it or change grants.
2. Open the target desktop app, sign in, and select the intended conversation.
   Wabi supports only the Wabi AI conversation, not human or group chats.
3. In msgblast, add the desktop app from **More agents**, enable it, and choose
   **Connect open conversation**. Dismiss dialogs and leave one main app window.
4. Select the agent and use the private or shared msgblast message box.

The adapter locates cua-driver in `~/.local/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`, or the app's inherited PATH. It uses the public `call` JSON
interface. It neither copies provider authentication nor uses the webhook.

## Conversation and send behavior

A connection records the conversation's displayed name. Keep that conversation
selected while a request runs; refresh or reconnect after changing app state.
Names are accessibility observations, not provider-issued conversation IDs.
Each comparison keeps its own local transcript, but the desktop app conversation
is shared across comparisons and can use its earlier context. This does not
create a fresh provider chat for each comparison.

Before sending, the adapter checks the exact process/window, conversation name,
and empty composer. It inserts text using a fresh element token, reads back the
prepared draft, and clicks the enabled Send control once. Every mutation uses
`delivery_mode: background`. A refusal never triggers foreground input or replay.
Existing drafts remain intact. The adapter does not launch or quit provider apps.

Only reply text after a newly observed outgoing prompt is returned. Known progress
controls defer return; otherwise text must remain stable for three seconds.
This is observed reply text, not a delivery receipt or proof that all provider
work has finished. In particular, providers may issue a later follow-up.
Cancellation stops waiting locally; it does not cancel work inside the app.

An incomplete request blocks further desktop sends across comparisons until the
user reviews and acknowledges it in the original comparison. No automatic resend
occurs. Saved drafts, attempts, and app conversation bindings survive reopening;
desktop bindings are never written as CLI session IDs.

## Verified capabilities and limits

On October 19, 2026, cua-driver 0.22.1 sent minimal prompts and read their exact
replies from Grok Bot and Wabi using background delivery. ChatGPT remained the
frontmost app after these tests. These were live account requests; they did not
exercise tools, attachments, new-chat creation, or long-running jobs.

Muse's main-chat composer was exposed as one compound button rather than an
editable field. Pressing that button opened an attachment picker. With explicit
foreground authorization, targeted Escape dismissed the picker. An initial
main-chat probe required foreground typing; a subsequent background pixel click
submitted it, and a background snapshot read `MUSE-OK-1019`.

A later **side-chat** investigation demonstrated a fully background path on the
same Muse 8.0 / cua-driver 0.22.1 installation:

1. Press the fresh `New side chat` accessibility button. A fresh snapshot showed
   an empty `New side chat` with `Back to main chat`.
2. Type a short test draft using screenshot-grounded background pixel focus.
   The screenshot showed the draft although the driver returned
   `effect: unverifiable` with `escalation.reason: delivery_failed`.
3. Append the minimal reply instruction through window-targeted background
   typing, verify the full draft in the screenshot, and click Send by pixels.
   The outgoing prompt and exact `MUSE-SIDE-OK-1019` reply appeared in both the
   screenshot and accessibility snapshot.
4. Send a second minimal prompt in that side chat using window-targeted
   background typing followed by Return. No pixel click was needed. A fresh
   snapshot read `MUSE-SIDE-SECOND-1019`. Typing had reported a zero-character
   partial result, which the screenshot disproved; the action was not replayed.

ChatGPT was frontmost before typing, after the first draft, after the first
reply, and after the second reply. These are discrete observations, not a
continuous focus/cursor/z-order oracle. No foreground delivery was used for
side-chat creation, either prompt, or reply reading. This supersedes the earlier
conclusion that Muse background typing was unavailable.

Automatic Muse sending is explicitly gated until side-chat identity and draft
verification are implemented. A generic `Muse` heading cannot distinguish the
main chat from different side chats, even if a future app version exposes a
standard editable composer. The tested Muse accessibility tree exposes one
compound button. Raw read-only AX inspection also found an
empty child list for that compound button; increasing the driver's tree depth
and element limits did not expose its inner controls. A read-only typed browser
bind refused Muse as an unrecognized browser process. The main-chat parser and
single displayed-name binding are also insufficient for separate side chats:
recent messages use `You:` plus plain text and reply controls, and the side chat
receives a generated title after its first prompt.

The integration needs to create and track the intended side chat per comparison
and independently verify its prepared draft before submission. This must not
reuse the main chat or assume a successful type result. No fixed pixel layout,
foreground fallback, OCR, or model-driven UI planning is enabled in the adapter.

A further observation found Muse on another Space with zero AX windows. Its
window capture still showed the two completed probes, but the driver marked the
AX surface unresolved and refused every background input route. No further input
was attempted in that state. Off-Space/hidden/minimized operation is not proven by
the successful visible-window side-chat tests.

The CLI's `elements_complete` flag was false even for full walks in this driver
version. The adapter instead checks returned/total counts and requires the app's
heading/composer sentinels; it cannot read history the app has not exposed.
User changes, duplicate conversation names, UI updates, virtualized transcripts,
and delayed replies can prevent reliable attribution. Review the app before
explicitly allowing another request. The shipped adapter uses no OCR, pixel
coordinates, or model-driven UI planning.

Demo runs simulate app replies and never start cua-driver or contact these apps.
Live probe captures contain private account history and are not public PR media.

## Automated regression coverage

`DesktopAppConversationTests` checks parser attribution, separation of desktop
accounts from web/CLI accounts, saved transcripts and drafts, and interrupted
request ownership across restart. Only the originating comparison can acknowledge
an incomplete request; another comparison cannot clear that guard.

`DesktopAppDriverTests` invokes the actual adapter through a temporary executable
that follows an independently specified sequence of JSON responses and records
its input arguments. It never invokes the installed driver or a provider app.
The tests cover:

- Grok Bot and Wabi submission with fresh composer/Send tokens and exact targets.
- False-negative/unverified typing: independent exact-draft evidence permits one
  Send, while partial, changed, or absent drafts prevent submission and replay.
- External drafts, changed chats before/after submission, ambiguous windows,
  missing/disabled/duplicate Send controls, refusals, and degraded/truncated AX.
- Repeated prompts and old answers, generation controls, composer clearing,
  bounded waits, cancellation, process cleanup, and per-app concurrent requests.
- No automatic foreground fallback, no automatic resend, and lifecycle cleanup.
- Muse main chats, untracked side chats, compound composers, and unresolved
  off-Space snapshots remain read-only until reliable tracking is implemented.

The fixture's shortened timeouts do not change production defaults. These tests
cannot establish real macOS focus preservation or current provider UI behavior.
They also do not claim to test automated Muse side-chat creation/resumption: that
feature remains unimplemented and gated. Before enabling it, add end-to-end
coverage for creation, generated-title changes, duplicate titles, exact identity
across comparisons/restart, and independent prepared-draft verification. The live
side-chat probes above are investigation evidence, not a substitute for that gate.
