# Desktop app conversations

Muse App, Grok Bot App, and Wabi are optional agents with msgblast's native
conversation pane. They use an independently installed `cua-driver` command.
The Muse website, Grok Bot webhook, and CLI agents retain their own accounts,
state files, histories, and execution paths.

## Setup

1. Install cua-driver using its official instructions. In msgblast, open
   **Settings → Permissions → Desktop app control**. Enable **msgblast
   Accessibility** for Muse's independent draft/identity checks. Enable the
   **CuaDriver** rows to open Cua's own Accessibility, Screen Recording and
   window-capture setup. macOS owns the grant decisions; nothing is enabled by
   opening Settings alone.
2. Install the desktop app on this Mac and sign in. Onboarding labels each app
   **Installed on this Mac** or **Not installed** before it can be selected.
   Settings also checks installation before allowing an app to be enabled.
   If it is installed but closed, **Open Muse**, **Open Grok Bot**, or **Open Wabi**
   opens it normally. Keep one main window on the current desktop and dismiss
   dialogs. Wabi supports only its AI conversation.
3. Choose Muse App, Grok Bot App or Wabi during **Apps** onboarding, or add it
   from **More agents**. Onboarding shows the same permission controls before
   connection. For Muse, choose **Check Muse connection**. For Grok Bot or Wabi,
   select the intended app conversation and choose **Check connection**.
   This read-only check verifies the conversation and composer without sending
   a test prompt or creating a side chat. A **Ready for your first prompt** note
   confirms the destination before Continue is enabled. Muse starts its own side
   chat with the first real prompt; Grok Bot and Wabi use the checked conversation.
4. Select the agent and use the private or shared msgblast message box.

The adapter finds cua-driver in `~/.local/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`, or its inherited PATH and uses its public `call` JSON interface.
Full Disk Access does not grant Accessibility permission. This prototype neither
bundles the driver nor copies provider authentication into msgblast.

Installation discovery validates the app's bundle identifier and executable; a
stale LaunchServices entry is insufficient. App removal or a process change clears
the in-memory connection check. A valid running copy takes precedence over a
registered path; its process ID is never attached to a different installed copy.
Before a send, msgblast rechecks installation and
running status. Saved conversations, drafts, and receipts remain intact if an app
is missing. Demo simulates installed apps and connection checks without contacting
them.

## Permission checks and consent

Settings and desktop-app onboarding share one permission view. The three rows
separate msgblast's Accessibility access from CuaDriver's Accessibility and
Screen Recording grants. Full Disk Access for Messages cannot satisfy them.
Browser and CLI onboarding does not request Cua access. Entering or reactivating
a desktop onboarding screen reads permission and installation status without
opening an app or inspecting its conversation. Even a saved connection
requires an explicit connection check before Continue is enabled;
cached readiness cannot advance setup automatically.

In the permission controls, Refresh and **Check again** run
`cua-driver permissions status --json`; this
read-only command does not start a daemon or show permission prompts. Grants
are accepted only when the report identifies the standalone CuaDriver daemon
(`com.trycua.driver`). Missing drivers, failed checks, and reports from another
permission owner remain unverified rather than showing Allowed.
**Check installation** only refreshes native installation discovery.

Only **Enable** or **Cua setup & capture check…** runs the supported
`cua-driver permissions grant` consent flow. Public `check_permissions` calls
cannot request grants. The setup command's exit does not establish access:
msgblast independently refreshes permission status afterwards. Allowed means a
macOS grant, not proof of current window capture; Cua's setup performs its own
capture check. Follow any macOS restart instruction, then check again. Demo
simulates every permission action and never invokes Cua, requests OS access, or
opens privacy settings.

## Muse side chats

Each comparison creates a separate Muse side chat. The first outgoing message
assigns a `/thread/{UUID}` address; msgblast saves that UUID and its comparison
owner after observing the exact outgoing message, before waiting for the reply to
finish. The first message includes `[msgblast request <UUID>]` followed by the
original prompt. This reference uses the already-saved attempt ID and prevents an
old chat with identical prompt text from claiming the new submission. It does not
add a second request; msgblast's local transcript keeps the original prompt.
Follow-up messages in a confirmed chat use the original prompt alone. The title is a navigation hint,
not the identity. Reopening a comparison checks the saved UUID, including after
Muse renames the chat or msgblast restarts. Duplicate titles cannot authorize
sending to another side chat.

Creation uses a fresh accessibility button. Muse's side-chat rows advertise
AXPress but that action does not select them. Resuming uses a background pointer
click derived from the row's current accessibility bounds and a fresh, validated
window capture. The saved UUID must match after selection. When needed, the empty
composer is focused through the same capture-based route before native focus is
verified. Captures are kept in owner-only temporary directories and removed after
the action. Missing captures, wrong window IDs, off-window frames, or image-size
mismatches prevent the click. If the saved chat is absent from
the exposed side-chat list, open it in Muse and try again. The adapter never
creates a replacement for a missing saved chat or adopts the main chat. Old local
Muse history without a tracked side-chat binding stays preserved and blocked.
An unsubmitted blank chat is reserved only in the running adapter; after restart,
a new empty side chat is prepared rather than adopting an arbitrary blank view.

Muse exposes its composer as a compound button, whose AXValue stays empty and
whose AX press opens a file picker. The dedicated reader uses read-only native
accessibility queries to obtain the web area's URL, verify the focused composer,
and independently read the actual draft. It distinguishes the empty placeholder
from a literal `Message` draft. It supports WebKit's visible-character ranges
and preserves Unicode. A private macOS window-number lookup correlates the AX
window with the driver's exact window ID; absence fails closed.

Typing targets the exact background window without pressing that compound
button. Small chunks require independent draft readback. Line breaks use
Shift-Return, because plain newline character events submit Muse's composer.
WebKit's extra terminal line break is tolerated only between chunks; the whole
final draft must equal the requested prompt before one final Return. Unsupported
control characters and unverifiable drafts stop input and preserve the text.
Typing and Send use no pixel coordinates. Navigation/focus coordinates come
from each fresh capture rather than a saved layout. No OCR, DOM injection,
foreground fallback, or automatic replay is used. A transient failed native read is retried once without repeating
an input action.

## Grok Bot and Wabi

These connections record the conversation's displayed name. Comparisons keep
separate local transcripts but share the app conversation and its earlier
context. Names are accessibility observations, not provider-issued IDs. Keep
that conversation selected while a request runs.

The adapter checks the exact process/window, conversation name, and empty
composer. It types with a fresh element token, independently reads the prepared
draft, and clicks the enabled Send control once. Every mutation specifies
`delivery_mode: background`; a refusal never triggers foreground input or replay.

## Replies, recovery, and limits

Reply attribution requires a newly observed outgoing message after the captured
baseline. Muse additionally checks the UUID, speaker boundaries, and unchanged
history; another outgoing request invalidates attribution. Known generation
controls defer completion. Otherwise reply text must stay stable for three
seconds. This is an observation, not proof that all provider work has finished;
providers can issue later follow-ups. Cancellation stops local waiting, not work
inside the provider app.

An incomplete request blocks further desktop sends across comparisons until the
user reviews and acknowledges it in its originating comparison. There is no
automatic resend. Saved drafts, attempts, transcripts, and side-chat UUIDs survive
restart. Desktop bindings never become CLI session IDs. A new UUID seen before
its outgoing message is saved separately as an unconfirmed recovery address.
After acknowledgement, recovery reopens that address and requires the matching
request reference before binding it. A missing or mismatched reference blocks
further input without creating a replacement or resending. If interrupted before
any new UUID is observed, the attempt stays uncertain without inventing an identity.

Live checks on October 19, 2026 used Muse 8.0 and cua-driver 0.22.1. Minimal
background prompts and exact replies were observed in all three apps. The Muse
adapter created two distinct side chats and verified a multiline Unicode draft
through its native reader. Fresh adapter instances then reopened both saved UUIDs;
a follow-up in the first chat returned the expected reply. A further new-chat
check verified the request reference, pending-address callback before ownership,
exact reply, and saved-UUID resume. Codex was frontmost before and after the earlier
resume run; other user apps were frontmost at the start and end of the reference
check. These checks do not establish continuous focus preservation,
off-Space, hidden, or minimized operation. A Muse window on another Space was
previously unresolved and background input was refused. App updates, virtualized
history, or user navigation can stop the adapter safely.

The driver's `elements_complete` flag was false even for full walks in 0.22.1.
The adapter checks returned/total counts and app-specific sentinels instead.
Demo simulates replies without starting the driver or contacting any app. Live
probe captures include private account information and are not public PR media.

## Automated regression coverage

`DesktopAppConversationTests` covers parser attribution, provider/account
separation, saved transcripts/drafts, and interrupted request ownership.
`CuaPermissionsTests` covers consent boundaries, permission-owner validation,
revocation, supported CLI commands through a temporary executable, Demo isolation,
and desktop onboarding progress. `MuseAppConversationTests` covers strict URL identity, immutable comparison
ownership, persistence, text ranges, placeholder versus literal drafts, and
speaker/baseline attribution.

`DesktopAppDriverTests` runs the actual adapters and WebAgentSession against
independently specified native observations and a temporary driver executable
that records every call. It never contacts installed apps. Coverage includes:

- Muse creation, early durable UUID capture, pending-address recovery after
  timeout and acknowledgement, old same-prompt chat rejection, duplicate/generated
  titles, reopening comparisons after restart, and missing-chat refusal without replacement.
- Exact draft verification, Unicode and multiline input, false-negative typing,
  partial drafts, focus loss, external drafts, and changed chats.
- Stable-reply waits, generation controls, old echoed prompts, and foreign replies.
- Incomplete sends across restart, explicit acknowledgement by the original
  comparison, cancellation, bounded process waits, and driver-process cleanup.
- Exact background targets, one submission, no foreground fallback, and no replay.
- Resized capture geometry, background composer focus without AXPress, invalid
  or missing capture refusal, and removal of private temporary screenshots.
- Grok Bot/Wabi token-based sends and degraded, truncated, ambiguous, or refused
  driver results. The generic Muse name-based route remains disabled.

Fixture timeouts are shortened without changing production defaults. These tests
prove adapter/controller behavior, not real macOS TCC grants or current provider
UI compatibility. Native UI suites need their separately authorized environment.
