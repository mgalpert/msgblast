# Desktop app conversations

Muse App, Grok Bot App, and Wabi are optional agents with msgblast's native
conversation pane. They use an independently installed `cua-driver` command.
The Muse website, Grok Bot webhook, and CLI agents retain their own accounts,
state files, histories, and execution paths.

## Setup

1. Install cua-driver using its official instructions. In msgblast, open
   **Settings → Permissions → Desktop app control**. Enable **msgblast
   Accessibility** for the apps' independent draft/identity checks. Enable the
   **CuaDriver** rows to open Cua's own Accessibility, Screen Recording and
   window-capture setup. macOS owns the grant decisions; nothing is enabled by
   opening Settings alone.
2. Install the desktop app on this Mac and sign in. Onboarding labels each app
   **Installed on this Mac** or **Not installed** before it can be selected.
   Settings also checks installation before allowing an app to be enabled.
   If it is installed but closed, **Open Muse**, **Open Grok Bot**, or **Open Wabi**
   opens it normally. Keep one main window on the current desktop and dismiss
   dialogs. Wabi creates a dedicated AI chat rather than selecting a contact conversation.
3. Choose Muse App, Grok Bot App or Wabi during **Apps** onboarding, or add it
   from **More agents**. Onboarding shows the same permission controls before
   connection. For Muse, choose **Check Muse connection**. For Wabi, choose
   **Check connection**. For Grok Bot App, choose a bot from the **Bot** menu in
   msgblast. Selecting it checks the connection automatically.
   Connection checks verify the conversation and composer without sending
   a test prompt or creating a side chat. A **Ready for your first prompt** note
   confirms the destination before Continue is enabled. Muse starts its own side
   chat with the first real prompt. Wabi starts a dedicated AI chat per comparison;
   follow-ups return to that saved chat. Grok Bot opens the bot selected in msgblast.
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

## Wabi dedicated chats

Each comparison creates a dedicated Wabi AI chat through **New chat**, then
**New chat** in the chooser. No contact, group, invitation, or existing personal
chat is selected. The adapter verifies a fresh thread address, empty composer,
New chat heading, and AI welcome message before saving the destination.

The `wabi://app/threads/` address is saved before typing the first prompt. Follow-ups
and reopened comparisons keep that exact address, including after a title change
or interrupted send. Resuming uses a sidebar link whose native AXURL matches the
saved address, then checks the opened thread again. Duplicate labels and missing
links require the user to open the saved chat in Wabi; no replacement is created.
The installed Wabi version did not respond to a background deep-link open request.

msgblast needs Accessibility to read Wabi's native address and actual composer
value and sender boundaries; cua-driver supplies background controls and input.
Both sources must agree on the prepared draft. Wabi 0.1.11 exposes
sender-specific message frames through
native `AXDOMClassList`; the reader validates their frame boundaries, sender
markers, footer timestamps, and reaction-control count. Unknown layouts stop the
adapter rather than guessing a speaker. This native contract can require an
adapter update after Wabi changes its UI.
An old comparison with Wabi history but no saved thread stays preserved and
blocked: start a new comparison to get a dedicated chat. Onboarding's check is
read-only and never creates a chat or sends a test prompt.

## Grok Bot

Choose the bot in msgblast's **Bot** menu during onboarding or in Settings. The
list comes from Grok Bot's sidebar, including its compact layout; loading the
list never sends a message or selects a bot. Selecting an entry opens that bot
and confirms readiness, with no separate Check connection button. **Refresh bots**
reloads the list. The choice is saved on this Mac and reopened before sending.
Automatic readiness and focus checks verify availability without switching bots;
only choosing a bot or sending a prompt opens it. If the saved bot has its own
draft, the send check preserves it and stops before typing.

This connection records the bot's displayed name. Comparisons keep
separate local transcripts but share the app conversation and its earlier
context. Names are accessibility observations, not provider-issued IDs. Keep
that conversation selected while a request runs. Missing, renamed, or duplicate
names require another selection; the adapter does not choose a substitute.

The adapter checks the exact process/window, conversation name, and empty
composer. In Grok Bot 0.71.2, the native `sand-conversation-heading` identifies
the actual chat header independently of headings inside a reply. msgblast's
Accessibility access reads that header and the composer's actual value; placeholder
text is never treated as proof of an empty draft. It types with a fresh element token, independently reads the prepared
draft, and clicks the enabled Send control once. Every mutation specifies
`delivery_mode: background`; a refusal never triggers foreground input or replay.

## Replies, recovery, and limits

Reply attribution requires a newly observed outgoing message after the captured
baseline. Wabi matches the exact new prompt and one response against unchanged
prior messages and native sender identities in either accessibility order; extra
messages or a second outgoing request stop attribution. A reply that echoes the
prompt remains a valid assistant response.
Muse additionally checks the UUID, speaker boundaries, and unchanged
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

A dedicated-thread check with Wabi 0.1.11 on the same date created a fresh AI
chat in the background, sent one fixed-response prompt, and observed exactly
`WABI-THREAD-OK-1019`. It then navigated to the existing Wabi AI chat and reopened
the saved dedicated address through the sidebar without sending another message.
A follow-up in that same saved thread produced `WABI-RESUME-OK-1019`. Switching
Spaces made the native window tree unavailable during observation; with approved
brief foreground access, the final sender-aware reader verified the existing
user/assistant pair without another submission. The prior app was restored.
Background use therefore requires Wabi's window to remain on the current desktop;
off-Space reads are not supported by this adapter.
The chooser exposed **Contacts on Wabi** rather than the earlier **Suggested**
heading; contact suggestions do not identify the New chat action. These local
checks used the current adapter source, not a distributed app build.

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
- Wabi creation through the AI chooser, exact URL resume despite renamed titles,
  missing/ambiguous chat refusal, immutable ownership, destination persistence
  before input, cancellation across restart, read-only onboarding checks, native
  sender boundaries, reversed accessibility order after reopen, echoed prompts,
  and refusal to attribute a foreign outgoing message as a reply.
- Grok Bot token-based sends and degraded, truncated, ambiguous, or refused
  driver results. Generic name-based Muse and Wabi sending stays disabled.

Fixture timeouts are shortened without changing production defaults. These tests
prove adapter/controller behavior, not real macOS TCC grants or current provider
UI compatibility. Native UI suites need their separately authorized environment.
