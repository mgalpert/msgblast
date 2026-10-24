# Desktop app conversations

Muse App, Grok Bot App, Wabi, Gemini, ChatGPT App, Dots App, and Claude App are optional agents with msgblast's native
conversation pane. They use the pinned CuaDriver executable bundled in msgblast, running as a
private embedded helper. No separate driver installation or CuaDriver app is
required.
The Muse website, Grok Bot webhook, and CLI agents retain their own accounts,
state files, histories, and execution paths.

## Setup

Onboarding starts with **Stats → Allow access → Choose your agents**. The access
screen shows msgblast permissions for Full Disk Access, Contacts, Automation,
Device Control and Data Access (Accessibility on older macOS), and Screen
Recording. App control has one permission owner: msgblast. The embedded helper
inherits the host's permission identity; users do not approve a separate
CuaDriver app. Full Disk Access does not grant app control. The page has no
manual check button or scrolling. Continue requires complete Messaging access
or complete app access. Permissions refresh automatically when returning from
macOS settings; saved progress never substitutes for a current grant.

With complete Messaging access, existing routable agents are added automatically
and selected in the chooser. Users can deselect them there; their opt-outs survive
permission review and restarts. Setup does not create Contacts, select send
recipients, or show a separate discovery or conversation picker. Missing or
unsupported conversations are not added. Older saved Messages setup steps resolve
automatically using their saved destinations.

Before any permission action, msgblast saves a checkpoint with the selected
agents, completed steps, drafts and current setup position. After a permission
restart it returns to Allow access and reads current grants again. Saved setup
progress never substitutes for live permission checks. A failed checkpoint save
prevents opening permission controls. Back returns to Stats with the user's
sharing choices intact.

1. In msgblast, use **Allow access** during onboarding or **Settings → Permissions**.
   Enable msgblast app control and Screen Recording for native app agents.
   macOS owns the grant decisions; opening Settings alone grants no access.
2. Install the desktop app on this Mac and sign in. Onboarding labels each app
   **Installed on this Mac** or **Not installed** before it can be selected.
   Settings also checks installation before allowing an app to be enabled.
   If it is installed but closed, the app's **Open** button
   opens it normally. Keep one main window available and dismiss dialogs. The window can be on
   another desktop; users do not need to move it. Wabi creates a dedicated AI chat rather than selecting a contact conversation.
3. Choose your agents after completing the access screen. Native apps share one
   compact connection checklist: choose **Connect** beside each app, or explicitly
   skip it for now. Continue stays disabled until every row is connected or
   skipped. Grok Bot keeps its bot picker in its row; Gemini keeps Chat/Task,
   model and thinking choices there. These checks send no messages. Each
   connected row confirms it is ready for the first prompt. A restart preserves
   selected agents but requires fresh connection checks. Settings keeps the
   full installation and permission controls for later changes.
4. Select the agent and use the private or shared msgblast message box.
   Starting a conversation opens its installed app automatically if it is closed,
   waits for one main window, then performs the existing connection and chat checks.
   Direct first prompts use the same launch step. Running apps with a usable main
   window are reused; an explicit start reopens an unavailable window. Background checks never launch apps. The explicit Connect action in onboarding opens a closed app before checking it; it does not create a conversation or send a prompt.
   A failed launch leaves the prompt intact and creates no send attempt; sign-in,
   permissions, an existing draft, or an unavailable window still need attention.
   Connected conversation panes show messages and their composer. Installation,
   enablement and connection controls live behind the header's options button;
   the same popover keeps Grok bot and Gemini mode/model/thinking choices
   available. An existing conversation that loses its connection shows a compact
   reconnect action instead of the setup panel.

The build embeds the official CuaDriver **0.38.0** executable at
`Contents/Helpers/cua-driver`, pinned by URL and SHA-256 in `scripts/cua-driver.json`.
Only the exact regular executable is extracted; the standalone app, SDK library,
and Node runtime are excluded. Build signing includes this nested executable.
The app launches the helper directly with `serve --embedded`, keeping it in
msgblast's responsibility chain. Provider authentication remains in each app.
The driver is not downloaded or discovered from PATH at runtime. Before reusing
a daemon, msgblast checks the host's current Accessibility and Screen Recording
grants. An observed grant or revocation starts a fresh private generation; calls
already in flight retain the old socket and are never replayed. A grant change
during startup fails closed before app control. Follow any host-restart
instructions from macOS.

Installation discovery validates the app's bundle identifier and executable; a
stale LaunchServices entry is insufficient. App removal or a process change clears
the in-memory connection check. A valid running copy takes precedence over a
registered path; its process ID is never attached to a different installed copy.
Before a send, msgblast rechecks installation and
running status. Multiple running copies of the preferred app bundle are refused
before any window is inspected or input is sent. Saved conversations, drafts, and receipts remain intact if an app
is missing. Demo simulates installed apps and connection checks without contacting
them.

## Permission checks and consent

Settings and onboarding use the same msgblast permission checks. App reading
and control share msgblast's Device Control and Data Access grant; Screen
Recording remains a separate msgblast grant. Full Disk Access for Messages
cannot satisfy these permissions. Consent remains explicit, and status checks
never request grants. Entering onboarding does not open a provider app or inspect
its conversations. A saved connection still requires a fresh explicit check
before Continue is enabled.

The embedded helper is owned by the app process and is not attached to an
unrelated globally running driver. Missing or failed permission checks remain
unverified. Demo simulates permission actions and never requests OS access or
opens privacy settings. Fixture tests do not prove real macOS attribution.

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
window capture. The saved UUID must match after selection. Preparing an empty
composer does not require WebKit to report editor focus: it can keep focus on its
outer web view until text arrives. The first text chunk focuses the unique current
composer using validated screenshot coordinates and types in the same background
call, without AXPress. The driver's `type_text` call uses the session's fresh
capture and does not accept a `capture_id` argument. Independent native draft and
focus readback must succeed before another chunk or submission. Captures are
kept in owner-only temporary directories and removed after
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
Both sources must agree on the prepared draft. Wabi 0.1.11 and 0.1.15 expose
sender-specific message frames through
native `AXDOMClassList`; the reader validates their frame boundaries, sender
markers, footer timestamps, and reaction-control count. Unknown layouts stop the
adapter rather than guessing a speaker. This native contract can require an
adapter update after Wabi changes its UI.
An old comparison with Wabi history but no saved thread stays preserved and
blocked: start a new comparison to get a dedicated chat. Onboarding's check is
read-only and never creates a chat or sends a test prompt. It verifies the exact
window, chat address, empty composer, and New chat control without parsing the
current chat's history. Wabi 0.1.15 can expose historical message frames without
complete reaction/footer metadata; those frames must not block onboarding.
Opening the New chat chooser also ignores unrelated history. Once the dedicated
chat opens, its welcome message is verified. Reply collection still requires
complete sender and message boundaries and stops rather than attributing
incomplete content.

## ChatGPT, Dots, and Claude native apps

ChatGPT App, Dots App, and Claude App use the installed Mac applications and
separate saved state from their website accounts. The installed ChatGPT
26.1013.40934 app (com.openai.codex) contains both ChatGPT and Dots. The older
com.openai.chat bundle is detected as installed, but its different native UI
is not yet supported by this adapter. Connection checks refuse unsupported layouts.

Starting or explicitly reopening a conversation opens a closed installed app
once and waits for its main window. Shared Send displays a getting-ready state
and pauses during launch; a configured closed app keeps its direct composer
available. A direct first send follows the same path.
Already running apps are reused when their main window is available; starting a
conversation reopens an app whose window is closed or on another Space. Native
app requests run in sequence so window launches do not compete for the active
desktop. Website requests can run in parallel. Polling, onboarding checks, and selecting a
blank draft do not launch apps. First-time sign-in stays in the native app.
If launch or readiness fails, no prompt is submitted and the draft stays saved.

Each ChatGPT and Claude comparison gets a dedicated chat. The first native
prompt includes a comparison reference while the local transcript keeps the
original prompt. Pending ownership is saved before typing; an uncertain first
send is never replayed or replaced automatically. ChatGPT saves the verified first
message and native title before attempting its dedicated title. If renaming fails,
the completed answer is retained and the original title can reopen the same chat.
Reopening always verifies the comparison reference. Claude saves the canonical native chat address as soon as its outgoing
message is observed and reopens it through Claude’s native URI handler. Both
verify the saved first message before follow-ups.

Dots continues the account’s existing dot. Its native app exposes no separate
new-chat action. Each comparison’s first prompt carries a reference, and follow-ups
require that reference in the observed dot history. msgblast never renames,
reboots, deletes, or approves actions for the dot. An unavailable reference or
changed dot identity blocks input until the saved context can be verified.

Native controls select the intended chat; the native accessibility tree verifies
sender boundaries, draft values, and ownership. Embedded browser tabs and app
content are excluded from ChatGPT’s transcript. Screen Recording lets Cua focus
these Electron message fields from fresh window geometry. Existing drafts and
active replies are preserved. Model choices remain those selected in the native
app. Unknown input outcomes are inspected without replaying the action.

## Gemini Chat and Task

Install the native Mac app from [Google’s Gemini download](https://gemini.google/mac)
and sign in there. Gemini uses the same msgblast app-control permission. Its native controls do not require window screenshots for input.
The Apps chooser puts native apps first and prevents selecting missing apps;
existing website accounts remain separate.

Choose **Chat** or **Task**, a **Model**, and an available **Thinking level** in
msgblast’s setup or native conversation pane. **Refresh Gemini options** reads
Gemini’s current native pickers; model names and thinking levels are not a fixed
account-wide catalog. Changing mode resets the model and thinking choice to the
native mode’s current selection. Configuration opens a blank chat when needed,
changes controls, and verifies their selected state without sending a prompt.
If a saved choice disappears, the available replacements are shown and the native
picker closes; sending stays blocked until you choose a valid replacement. A
model without separate effort controls offers **Use Gemini’s default thinking**.
The connection check itself only reads the open conversation and draft.

Each comparison owns a dedicated Gemini conversation. Mode is fixed after its
first prompt because Gemini removes the Chat/Task switch after a chat starts.
Start a new comparison to change mode. Model and thinking choices are saved per
comparison and verified before sending. Models without a thinking-level control
use their native reasoning behavior; msgblast does not invent an effort setting.

Gemini 1.131.4.1198 exposes no canonical chat address through its native
accessibility tree. After a completed first response, msgblast saves its verified
first outgoing message, observed title, and intended `msgblast <comparison UUID>`
title before attempting the optional rename. A failed rename keeps the observed
title as a resumable fallback and still returns the completed reply. The first prompt includes a comparison reference; the local
transcript retains the original prompt. Resuming requires a unique sidebar
button, the saved dedicated or fallback title, and the matching first message. A renamed or missing
conversation is refused rather than replaced. An interrupted first submission
is saved after configuration succeeds, immediately before input, and blocks
automatic replacement, including after restart. Known model-choice refusals stay
not sent and do not reserve a conversation.
Review Gemini and start a new comparison if that initial binding could not finish.

The native reader correlates Gemini’s exact window number and independently
reads draft values, native control identifiers, selected mode/model, and transcript
rows. Gemini’s WindowServer title is empty, so discovery requires one on-screen
main-size window followed by native validation. Virtualized inaccessible sidebar
rows cannot supply navigation targets. Cua actions use fresh tokens matched to
native control frames, always with background delivery. There is no automatic
foreground fallback. Unknown action results are reobserved, never replayed.
Transient native observations, including an unavailable exact window during
a sheet transition, get at most two read-only retries at the polling interval.
A persistent failure stops that operation without repeating its input.

A response needs the exact new outgoing message, unchanged prior transcript,
a completed answer with its native Copy response control, no Stop response control,
and stable text. Task status headings such as “Thinking it through” and “Completed”,
and usage notices, are excluded from answer text. Unknown answer layouts stop
attribution. Transient incomplete native walks during response generation reset
the stability timer and retry observation within the existing reply deadline;
input and Submit are never replayed. Cancellation stops local waiting; it does
not cancel Gemini’s work.

Live characterization on October 20, 2026 with cua-driver 0.22.1 observed one
minimal Chat echo and one minimal Task echo, both returning their expected text.
The Task response showed a distinct working status before its completed answer.
Chat/Argon exposed Low, Medium, and High thinking levels; Task exposed Flash and
Argon without a separate thinking submenu in this version. Controls and options
may change with the app or account. Initial off-Space typing was refused; brief
user-authorized foreground initialization enabled subsequent background operations.
The final adapter also submitted a minimal Chat prompt once, read its exact
answer, saved the dedicated conversation title, and sent/read a follow-up in
that same saved conversation through background controls.
These checks do not establish minimized, hidden, or unattended off-Space operation.
Research captures contain private sidebar information and are not PR evidence.

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
text is never treated as proof of an empty draft. Typing uses the current editor's
validated capture geometry and independently checks each prepared draft. Focus
must remain confirmed between keyboard chunks. After the last chunk, the exact
draft and conversation are checked before the enabled Send control is clicked
once; that button does not require keyboard focus.

Grok virtualizes older messages when its transcript scrolls. msgblast anchors on
the latest conversation messages instead of counting every loaded occurrence of
a prompt. A new outgoing prompt and reply must appear after that unique anchor.
Missing or duplicate anchors, changed recent history, or another new message
stop attribution. No usable history stops input; a completely empty new bot has
no independently verified empty-chat contract yet. Every mutation specifies
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
inside the provider app. Gemini Chat waits up to three minutes; Task waits up to
30 minutes so a longer reasoning task can finish without another submission.
Both modes keep Cancel available. Cancelling preserves an unconfirmed receipt
and the draft rather than treating the request as unsent.

An incomplete request blocks further desktop sends across comparisons until the
user reviews and acknowledges it. Other comparisons identify the blocking
request and offer explicit acknowledgement of that exact attempt. There is no
automatic resend. Saved drafts, attempts, transcripts, and side-chat UUIDs survive
restart. Desktop bindings never become CLI session IDs. A new UUID seen before
its outgoing message is saved separately as an unconfirmed recovery address.
After acknowledgement, recovery reopens that address and requires the matching
request reference before binding it. A missing or mismatched reference blocks
further input without creating a replacement or resending. If interrupted before
any new UUID is observed, the attempt stays uncertain without inventing an identity.

### Earlier live checks

The following checks predate the embedded runtime and exact-window lookup across
desktops. Their stated app versions, revisions, and limitations describe those
runs, rather than the current validation status.

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
At that revision, background use required Wabi's window to remain on the current
desktop; off-Space reads were not supported.
The chooser exposed **Contacts on Wabi** rather than the earlier **Suggested**
heading; contact suggestions do not identify the New chat action. These local
checks used the current adapter source, not a distributed app build.

On October 21, 2026, local checks of the actual adapters against ChatGPT
26.1013.40934 (`com.openai.codex`) created a dedicated chat, observed the exact
fixed response, saved its dedicated title, and reopened it from the Dots view for
an unprefixed follow-up. Dots verified the account's existing dot, retained the
first comparison reference, and observed a fixed-response follow-up. Its native
rendered paragraphs require separate paragraph boundaries, and older history
can load above the unchanged observed baseline after sending. Claude 3.1623.0
created a dedicated conversation, saved its canonical address, and reopened it
from a blank chat through its native URI handler before observing a follow-up.
Foreground access was authorized for these checks; other-Space background access
was not established. These were adapter harness checks using live native apps,
not validation of a distributed msgblast build or fresh macOS permission grants.

The driver's `elements_complete` flag was false even for full walks in 0.22.1.
The adapter checks returned/total counts and app-specific sentinels instead.
Demo simulates replies without starting the driver or contacting any app. Live
probe captures include private account information and are not public PR media.

## Automated regression coverage

`ChatGPTAppConversationTests` and `ChatGPTAppSubmissionTests` cover sender
boundaries, semantic headings, native paragraph spacing, exact chunked input,
transient observations, saved-title reopening (including zero-height sidebar
rows), failed-rename recovery, immutable fallback ownership, and Dots history
loading without accepting interleaved or extra new messages. `ClaudeAppConversationTests`
and `ClaudeAppDriverTests` cover canonical URLs, native URI resume, rich draft
refusal, paragraph boundaries, interrupted sends, and one-shot submission.
`NativeDesktopStateTests` covers migration, separate provider state, immutable
bindings, fixture reloads, shared ChatGPT/Dots installation reuse, and sequential
native preparation. `DesktopAppInstallationTests` holds launches across quick
selections and comparison changes to prove that abandoned work cannot reopen or
submit into another comparison. Controller fixtures exercise the actual AppModel
and LocalStore restoring all three native providers. These are simulated inputs;
the live checks above establish compatibility only with the observed app versions.

`GeminiAppConversationTests` covers native Chat/Task boundaries, progress and
usage-notice exclusion, actual draft values, legacy state, immutable ownership,
and comparison-specific preferences. `GeminiAppDriverTests` exercises the real
adapter through a temporary driver process: exact targets, one submission with
an unknown click result, dedicated-title persistence, foreign outgoing refusal,
interrupted-first-send protection, session reload, saved-chat follow-ups, and
select/reopen/verify of thinking choices. It also checks saved sidebar-row
navigation, rejection of duplicate titles or foreign first prompts, and Task
completion after the Chat wait limit with only one submission. The driver fixture requires the exact
action, target and text before advancing. These inputs are synthetic and do not
contact Gemini.

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
- Resized capture geometry, explicit first-input targeting without AXPress, invalid
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
