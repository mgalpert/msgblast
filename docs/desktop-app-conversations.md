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

Muse's message history was readable, but its composer was exposed as one compound
button rather than an editable field. Pressing that button opened an attachment
picker. With explicit foreground authorization, targeted Escape dismissed the picker.
Background pixel typing left the composer empty; foreground pixel typing inserted
the test prompt. A subsequent background pixel click submitted it, and a background
accessibility snapshot read the exact reply `MUSE-OK-1019`. This mixed-mode test
does **not** establish a fully background workflow or foreground preservation for
submission. The adapter refuses to connect when it cannot identify a unique
editable composer, so automatic Muse sending remains unavailable. The shipped
adapter has no foreground fallback.

The CLI's `elements_complete` flag was false even for full walks in this driver
version. The adapter instead checks returned/total counts and requires the app's
heading/composer sentinels; it cannot read history the app has not exposed.
User changes, duplicate conversation names, UI updates, virtualized transcripts,
and delayed replies can prevent reliable attribution. Review the app before
explicitly allowing another request. No OCR, pixel coordinates, or model-driven
UI planning is used in the shipped adapter.

Demo runs simulate app replies and never start cua-driver or contact these apps.
Live probe captures contain private account history and are not public PR media.
