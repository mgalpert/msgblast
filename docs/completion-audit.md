# Completion audit — October 2, 2026

Historical audit of the original Messages-focused implementation. Status and
permission observations below belong to that date and the revisions named in
the record. They are not the current release status or today's contributor
checklist. Use [the documentation index](README.md) and [Testing](testing.md)
for current setup and validation.

The original `plan.md` remains the completion contract, with the user's later native Messages styling, link previews/reaction display, pinned compose, attachments, and connected-window default instructions applied. The October 1 connected-window request expressly supersedes separate-only window decisions: separate windows remain available in Settings. Source implementation and fixture evidence do not prove the live integration. The full goal is not complete.

## Initial evidence (superseded by subsequent verification updates)

- The Xcode result at `build/Logs/Test/Test-msgblast-2026.10.01_15-33-43--0700.xcresult` reports 23 tests passed, zero failed or skipped. Its scope is core logic, SQLite fixtures, and native AppKit paste/editor tests.
- Five native workflow tests compile. Their prior execution failed because macOS denied the runner's UI actions; compilation does not establish a passing suite.
- Actual Messages UI evidence demonstrates an ordinary send and a genuine inline reply to the authorized single test chat. It does not demonstrate msgblast's own send implementation or exact GUID linkage.
- Earlier manual isolated demo evidence covers separate conversations, private/shared scope, retry, reopening, selectable transcript text, native fetched link images, and synthetic reactions. It predates the pinned composer change.
- The pinned composer was mocked with built-in ImageGen before implementation. Its final source places the input at the bottom, uses a direct toolbar +, and shares one selection action across each avatar and its check. Runtime verification is pending.
- Current Computer Use cannot open the demo because the Mac is locked. A current read-only shell schema probe of Messages was denied. No permission was bypassed and no new live message was sent in this audit.

## Current requirement status

This table replaces the older pending-only claims. Previous live results identify the tested revision and do not establish permission for the current development signature.

| Requirement | Authoritative evidence | Remaining completion gate |
| --- | --- | --- |
| R1: native macOS and existing account | SwiftUI/AppKit builds; controlled sends to Michael and Pal; host reports macOS 27.2, build 26B5091g; October 2 09:28 rebuilt app reads history and sends self-address files | Later photo-layout/Contacts-consent source remains to be deployed and checked |
| R2: Contacts names, handles and avatars | Real Add created/reused Contact IDs for Pal and the pending Outlook address; native picker fixture passes | Final Contacts/photo and denied-access recovery checks |
| R3, revised: manual contacts can be saved; sends require existing one-to-one chats | Pending Outlook Contact saved without a send; eligible-route guards and pending-contact native test pass | Pending Outlook verified disabled/unselected after current grant; no registration is inferred from contact creation |
| R4: newest eligible route and destination preview | Resolver fixtures choose newest of multiple handles and reject groups/SMS; picker/tooltip exposes chosen handle | Actual controlled multi-handle route inspection |
| R5: dynamic pinned selection | Native avatar/check/default-selection workflow and subset/empty selection fixtures pass | Current-build live eligibility/selection inspection |
| R6: separate identical copy per selected chat | Controlled initial/shared text sends reconciled distinct Michael/Pal anchors; native Pal text Delivered; independent three-member fixture | Current-build final live copy/count checks |
| R7: per-recipient acceptance, failure and safe retry | Durable receipts, partial retry/restart fixtures and native retry workflow; new optional history delivery fields tested | Not Delivered verified for the actual failed PNG/TXT; final no-duplicate live recovery remains |
| R8: anchor-forward live updates | Prior live outgoing/incoming self-echoes and actual Pal reaction displayed; read-only/data-version fixtures pass | Current external reply/update, body representation and live schema verification |
| R9, revised: one universal editor selects private scope in joined mode | MB1001-2010 private text; October 2 fresh PNG/TXT sent only to Michael with Pal excluded; native joined selection/draft workflow passes | Later polish revision must retain this verified routing |
| R10, revised: joined shared editor by default; separate panel optional | MB1001-2016 shared send to Michael and Pal; persisted scopes and optional layout fixtures pass | Final current-build shared flow and optional panel interaction |
| R11: saved starts and reopen | Controlled live comparison reopened without another send before concurrent rebuild; local recovery fixtures pass | Current permission/restart/reopen confirmed October 2; final rebuilt revision remains |
| R12: per-agent bounds plus later explicitly related replies | Ordinary-range/nested-reply fixtures; current live older view excludes Michael's newer MB1002-0940 prompt while retaining earlier files and Pal | Genuine late thread relationship across that newer comparison |
| R13: original-prompt context for old comparisons | Native Reply UI observed; live MB1002-0944 guard preserved the draft and created no follow-up attempt | App-driven exact original target and confirmed database linkage, or explicit user-approved requirement revision; decision requested |
| R14, revised: one connected window by default | Native joined workflows pass; separate preference persists; six-column Demo verified | Final current live window evidence |
| R15: independent optional window movement/association | AppKit identities/frames and layout-switch receipts verified | Actual independent drag/reopen remains unverified |
| R16: readable horizontal overflow | Six-agent fixture/navigation evidence retains readable width and accepted anchors | Final optional-window overflow/association check |
| R17, revised: individual agent names and actual scope | Named pills reflect selection; native private/excluded/shared workflows pass; saved live membership matches | Final scope inspection on current live executable |

Additional requested scope remains part of completion: native Messages appearance and side-by-side evidence, real traffic lights/glass, image/link previews, reaction display, Photos/files/paste/drop, actual attachment transfer, the native onboarding drag flow, Contact creation, joined default, and a correct Dock icon. The native onboarding return workflow passes; current OS-granted history access was confirmed after the October 2 restart. Pal's actual reaction renders; the earlier PNG transfer is explicitly failed in Messages. The stronger native preview test verifies actual opaque blue/green pixels, closing and reopening the same image, and a reopened comparison. The final rebuilt live preview and transfer remain to be verified. Discover's source/description copy was corrected to avoid visible protocol-brand wording while retaining source data and URLs; deployment into the live app remains pending the consolidated build.

## Acceptance examples and implementation units

- AE1/AE2: prior app-driven Michael/Pal copies and private/shared scopes are observed. External agent acknowledgement and current-build end-to-end checks remain open.
- AE3: range logic passes fixtures; exact original-prompt app reply remains blocked by R13.
- AE4: six-column geometry and actual Demo overflow navigation are observed; independent drag and final live evidence remain open.
- AE5: newest route and retry eligibility pass fixtures; final UI retry/count assertions and actual multi-destination routing remain pending.
- U1/U3/U4/U5/U6 have production code in the consolidated App/Contacts/Core/Messages/Storage/Windows modules rather than every proposed file name in the plan. Their live verification remains incomplete as listed above.
- U2 remains incomplete: ordinary app sends and outgoing anchors are observed, but actual schema/body and exact original-prompt inline linkage remain open.
- U7 remains incomplete: clean setup, permission grant/deny/revoke/restart, final end-to-end workflow, and final running evidence are not all proven.

## Remaining verification contract and deliverables

Build and core fixtures are proven within their stated scopes. Fixture database bytes remain unchanged; the production connection is opened read-only. The live private schema/body and source records have not been independently checked through the final executable. The app-owned local store retains metadata, app-authored prompts/drafts, anchors, attempts, and frames, not imported history.

No remote or PR exists. The user's PR Screenshots and Video rule applies if a PR is created or updated. Existing local images and generated mockups cannot be presented as final reviewed PR evidence. A Mac-only UI requires desktop evidence, with a playable interaction video within the repository's access boundary.

Immediate next action after the Mac is unlocked: restart the final demo and verify default checks, avatar/check hit areas, bottom input, + sheet, a selected subset's separate sends, and six-window navigation. Then revalidate the final live executable's permissions before the minimum authorized live integration checks. Keep R13 unavailable until genuine linkage is demonstrated; do not substitute quoted text or claim v1 completion.

## Subsequent verification update

Pinned selection, both avatar/check coordinate hit areas, bottom input, direct + picker, selected-subset send, and all-selected relaunch were manually observed in the running demo. Actual live reads worked after the user's Full Disk Access change, and an existing authorized Contacts agent was added and selected. The user's subsequent manual-account request adds real Contacts creation on Add and persistence of its ID; the fixture path is verified with a simulated ID, while the actual write remains pending. The final rebuild again lost Full Disk Access after signing. The Mac was unlocked for those checks; the latest Computer Use check reports it locked again. These observations replace the earlier lock status, but do not establish the remaining live send, thread linkage, UI runner, or v1 completion gates.

## Attachment scope update

Photo/file attachment support and the circular native plus are built. Final fixture verification covers shared/private scopes, attachment-only sends, native picker/Quick Look, Finder-file and Preview-image paste, saved drafts, and partial retries preserving accepted receipts. All 23 core/AppKit tests pass. Final screenshots and limitations are recorded in integration-findings.md. The current live executable still reports Full Disk Access denied after rebuilding; actual attachment delivery and Contacts creation are not claimed verified. Original R13 and remaining full-plan live gates remain open; the overall goal is not complete.

## Connected-window default update

The user requested one connected comparison window as the default, with separate windows available in Settings. This supersedes the original separate-only decisions in R10/R14/R15 and KTD1; it does not change independent chat membership, private/shared input scopes, anchors, retries, or R13. `plan.md` remains unedited.

The connected workspace and native radio-button Settings are built. Existing state without a preference defaults to connected; the preference and each layout's frames are persisted. Switching immediately reconstructs only open comparison windows while retaining drafts and receipts. Demo checks verified private versus all-member sends, both drafts across layout changes and restart, Settings retaining focus, and six-member horizontal navigation/retry. Local saved-state assertions proved layout switches added no send and a six-member retry preserved the five accepted anchors. Two preference regressions first failed on missing APIs and now pass.

The final core/AppKit result `build/Logs/Test/Test-msgblast-2026.10.01_15-57-49--0700.xcresult` reports **25 passed, zero failed or skipped**, with no runtime warnings. The five native workflow tests compile; the UI runner's prior access failure remains unresolved. Manual checks and local screenshots are simulated Demo evidence, not real delivery proof. Three scoped simplification reviews completed; one efficiency finding was applied by batching close-time state saves. No formal shipping receipt or PR is claimed.

The final live executable still requires a current Full Disk Access grant. Actual Contacts creation, app-driven live sends/updates/attachments, native test-runner access, and genuine original-prompt targeting remain unverified. The full goal remains active and incomplete.

## Joined universal input update

The user superseded the connected window's per-column editors with one universal editor. New and legacy comparisons default to everyone. Selecting a transcript/avatar targets only that conversation; clicking a name pill toggles its shared exclusion and returns to the remaining shared recipients. The native menu displays the target scope and Everyone clears exclusions. Repeated selection stays private. Target changes and layout changes preserve the universal draft. With no recipients, Return adds no send and retains the draft. Retries use the saved attempt's original membership.

`Test-msgblast-2026.10.01_16-15-26--0700.xcresult` reports **28 core/AppKit tests passed**, zero failures/skips and no runtime warnings. The five native UI workflows compile but have no passing authorized XCTest run. Manual Demo sends and saved-state assertions verified everyone, Cedar only, and Lumen/Orbit with Cedar excluded. Layout switches preserved recipients, draft, and all receipts without adding a send. Final build accessibility labels distinguish selecting a conversation from excluding its name pill. This supersedes the earlier connected evidence showing four editors. Live integration and R13 remain open.

## Named recipient pills update

The user requested visible individual contacts above the joined input, highlighted by default and toggled off when tapped. This supersedes the count/menu control and the earlier behavior that returned to all shared recipients after a private selection. Each pill now represents its actual membership in the next send. After selecting one conversation, tapping another pill adds only that agent; tapping the selected pill removes it. Both the header pills and footer row reflect the same target set. Zero recipients retain the draft and cannot send.

Core/AppKit result `Test-msgblast-2026.10.01_16-37-53--0700.xcresult` reports **28 passed**, zero failures/skips/warnings. A pre-pill joined workflow passed (`16-29-26`), with an internal QoS warning. The rebuilt five-workflow suite (`16-34-28`) failed: one lost helper connection and four denied UI-testing authorization. It is not passing current UI evidence. Tests now launch with `--isolated-demo`, which creates a fresh temporary store per launch and cannot reset the normal Demo store. The final pill layout is verified manually in Demo; live permissions and R13 remain open.

Final manual Demo proof for the pill update: all-selected initial state, exact Lumen/Orbit submission after Cedar deselection, exact Cedar/Orbit submission after expanding private focus, and empty-selection draft preservation without another send. These checks are simulated and do not satisfy the remaining live gates.

## Final separate-window overflow check

In the compiled Demo, the six-agent floating navigator brought the sixth conversation into a readable 390-point window with the matching saved prompt and private editor. Its frame moved into the visible display at x=1102. Actual local screenshot evidence and saved-state assertions prove no comparison/draft/receipt changed. The connected preference was restored, and the joined view displayed all six named pills selected and one input. This completes the remaining separate-window overflow fixture check for R16.

Cedar's independent drag/reopen check remains unverified: Computer Use drag attempts produced no stored position change. Live msgblast Check again still returned denied history access. No process or test is still running, no permission was bypassed, and no live test message was sent. R13 and the other live gates are still required before declaring the goal complete.

## Live send and pending-contact fix update

Live msgblast submitted controlled MB1001-1657 text to mgalpert@gmail.com and palcowen@gmail.com and reconciled both outgoing anchors. Native Messages showed Delivered for palcowen. The real Add path created/reused palcowen's Contacts record and persisted its identifier. No external ack was observed. These checks supersede the earlier blanket statements that live app sends and real contact writes were unverified. The limited receipt extract is under docs/evidence.

msgisaway@outlook.com remains unregistered in native Messages and was not sent any message. The user correctly identified that contact creation must not depend on existing chat eligibility. Search/Add/save guards were corrected, pending agents remain saved/unselected, and refresh prunes unavailable selections without broadening the user's valid selection. The 30-test Core/AppKit suite passes, and the corrected native workflow compiles. The Mac is locked; corrected live Add, visual evidence, and final executable permissions remain pending unlock. Native reactions, live attachments/updates/follow-ups, runner access, independent drag, and R13 remain open. The full goal stays active.

## October 1 evening live verification

The final onboarding tests supersede the old UI-runner authorization failures: 41 tests passed (34 core/AppKit/controller and seven native workflows) at `19-56-45`; after the final Settings-close fix, 36 passed (35 core/AppKit/controller and the native guide interaction) at `20-00-23`. These are distinct verification runs, not a claim that the combined 42-test suite ran. Details and genuine native guide evidence are in `docs/evidence/onboarding/validation.md`.

After the user enabled Full Disk Access, regular msgblast read live history. The corrected manual Add path saved `msgisaway@outlook.com` with a real Contacts identifier; the pending avatar remains disabled and unselected because there is no eligible conversation. Contact creation does not register the address for messaging. No message was sent there.

In the controlled MB1001-1657 comparison, the live universal input sent MB1001-2010-private only to Michael and MB1001-2016-shared to Michael and Pal. Saved attempt membership matches those scopes and both texts reconciled to outgoing anchors. Michael's self-addressed chat displays outgoing and incoming echoes, while Pal's column omits the private text. Pal's original prompt displays the actual ✅ reaction. No external agent acknowledgement is inferred from Michael's self-echo.

Using the native file picker, attachment-only synthetic PNG sends to both authorized chats reconciled to individual anchors and appeared as image cards in both live columns. An attachment-only synthetic text file sent privately to Michael reconciled and appeared only in that column. Limited app-owned evidence is in `docs/evidence/live-scope-and-attachments-MB1001-2025.json`. Submitted/anchored states establish submission/history reconciliation, not external delivery.

A live defect was found: clicking an image in the joined transcript opens Quick Look with “No items selected.” This invalidates the prior broad Quick Look claim for live joined transcript previews and is under investigation. Native image cards themselves load. R13 exact original-prompt targeting remains incomplete.

The regular app was quit/reopened without rebuilding and the controlled saved comparison reopened with its prior messages and scopes. No send was triggered by reopening. Later another authorized chat rebuilt the canonical Debug bundle while live tests were underway, so the binary on disk is no longer the same approved revision as the process used for those observations. Further regression work uses a frozen isolated app and separate derived-data folder. The user authorized coordination of the icon and Discover chats to prevent replacing the running bundle during validation.

### Qualification after attachment diagnostics

The live attachment anchors/cards remain observed, but filtered synthetic-file logs also show Messages attachment-processing access errors. External file delivery is therefore unverified and must not be inferred from the local outgoing records. The empty live Quick Look panel has not reproduced in a stable isolated app: its native screenshot shows the selected image correctly. `docs/evidence/dock-placeholder-investigation.md` records the concurrent build overlap, actual resolved icons, selector/assertion limitations, and remaining stable-build checks. No preview implementation change has been made yet.

### Confirmed delivery failure and status fix

After unlock, native Messages showed Pal's MB1001-2016 shared text as Delivered and the synthetic PNG as Not Delivered. Its Quick Look preview correctly identifies the PNG. msgblast previously omitted downstream delivery-error fields entirely, so the local submitted receipt hid this failure. The read-only adapter now carries an outgoing-only delivery state: a nonzero error takes precedence over a delivered flag; absent columns and pending/incoming rows remain unknown. Transcripts show red Not Delivered beneath failures and Delivered only under the latest outgoing message with a positive delivery flag. Submission receipts and retry rules are unchanged; accepted parts are never automatically resent.

The two new adapter regressions first failed compilation on the missing delivery API in the isolated Xcode project. The canonical-source core/controller run at 20:57:08 passed all 39 tests. A subsequently reused frozen snapshot had one unrelated Discover regression failure because its catalog implementation was older than the current test source; that source mismatch was corrected before final validation. The saved generated-image Quick Look regression passed at 20:58:32. The earlier SwiftPM attempt is not passing test evidence: its target cannot see the existing app-controller lifecycle tests.

Simplify: skipped for overlapping pre-existing edits. Code review: targeted manual due to unrelated branch work. No mixed-tree commit, remote, issue or PR was created. The full goal remains active: current live permissions, real attachment transfer, Dock rendering and genuine R13 original-prompt reply targeting still require verification.

Final isolated production-source validation at 21:00:11 passed **47 tests** (39 core/controller and eight native workflows), zero failures/skips, with four internal XCTest QoS warnings. The reused frozen-source Discover mismatch no longer occurs. The live canonical app was closed before rebuilding, built successfully at 21:03:52, passed strict signature verification, and was relaunched from its complete path. Its current Full Disk Access switch is off, independently observed in System Settings; the user has been asked to refresh that existing approval. Native metadata resolves an icon and reports a regular foreground app; actual Dock rendering awaits observation.

Visual-evidence qualification: the passing Quick Look test exposed the correct selected-image identifier, but its screenshot was taken before pixels rendered. That empty transition image is not retained as final feature evidence. The test was strengthened to generate a larger blue/green fixture and wait for both colors in the actual panel screenshot. This test-only revision compiled, but its run was interrupted by a Codex dialog and was stopped; the strengthened assertion is not claimed passed. The 47-test result applies to the production-source revision and earlier accessibility-based preview check. No preview implementation change is inferred from this timing artifact.

### Preview fixture correction and current desktop gate

The isolated retry was stopped after macOS/XCTest interruption handling encountered a system dialog and other application windows before reaching the preview. Its handle is terminal (exit 75); it is not a running wait or a passing test. The fixture itself emitted unsupported color-space warnings while writing named/sRGB NSColors into NSBitmapImageRep. Its earlier blank screenshot cannot be attributed solely to rendering timing. The test now writes explicit opaque RGBA samples into the bitmap instead. An independent ImageIO/CoreGraphics decode of the exact generated PNG verified 320x180 dimensions, full alpha and blue/green regions without warnings. This corrects test input only; the stronger native pixel assertion still needs a real run.

The subsequent native UI check reports the Mac locked and automatic unlock unavailable. No unlock, OS grant, attachment resend or canonical app rebuild was attempted. The last accessible Full Disk Access observation showed msgblast off. Current permission, Dock appearance, live attachment transfer and R13 remain unproven. The prior goal turn made progress through the delivery-status implementation and passing checks; this turn corrected and verified test data while leaving the full goal active.

The corrected preview test compiled at October 1, 23:59 in the isolated project. Independent ImageIO/CoreGraphics PNG decoding and the saved color predicate both pass without warnings. These are test-input/predicate checks, not a screenshot of native Quick Look. No live bundle was replaced during this correction.

Latest consistent source snapshot: `Test-msgblast-2026.10.02_00-09-38--0700.xcresult` passes **39 core/controller tests**, zero failures/skips. The corrected native workflows compile; they were not executed while locked. The snapshot includes the latest Discover constructor/catalog changes from the other authorized chat, avoiding the earlier mixed-snapshot type-check failure. Build output includes an AppIntents metadata warning; the test runtime logs shortcut-service and synthetic file-URL sandbox messages. No clean-warning claim is made. The new pixel helper is explicitly main-actor isolated, so its prior actor warning is resolved.

Discover's displayed source is now “Agent directory”; its displayed taglines and tagline tooltips use “Messages.” The raw catalog, destination URLs and messaging-service identifiers remain intact. The other chat was informed under the user's coordination authorization. This is compiled source work only; the live canonical bundle is intentionally unchanged until live access/transfer diagnosis is complete.

## October 2 resumed verification and attachment fix

After the user's Ready, the unchanged canonical October 1 21:03:52 executable successfully read live history. Continue dismissed the completed onboarding row. Restarting the same bundle retained history, the controlled comparison, names, private scope, reaction and attachments without sending again. Pending Outlook remained disabled and unselected. The current build displays Not Delivered under both Michael's PNG/TXT and Pal's PNG; earlier submitted/anchored receipts must not be mistaken for transfer success.

Native Quick Look still opened No items selected for live transcript and freshly staged draft images. The filtered msgblast log explicitly reports calls while the preview panel has no controller. The stronger isolated blue/green pixel regression first passed on the prior production implementation at 08:52:33; this does not negate the live failure. A hosting-controller-only experiment passed the fixture but did not establish a live fix and was discarded. The production change now supplies an explicit native NSView responder/data source for the selected file through Quick Look's begin/end control lifecycle. The saved native screenshot is `docs/evidence/attachments/quick-look-synthetic.png`; it contains synthetic input only.

Messages' sandboxed attachment processors rejected the prior app-data paths. Investigation of the openclaw/imsg sender identified private transport copies under Messages' attachment namespace. msgblast now keeps the saved draft in its own store and creates a distinct private transport copy per recipient under Library/Messages/Attachments/msgblast-Outgoing. Directory/file permissions remain 700/600, symlink roots/sources are rejected, metadata cannot redirect the destination filename, and the copy is retained for asynchronous native processing. No message database records are edited. This transport change needs an actual live delivery check before it is claimed fixed.

The 09:12:33 isolated result passes 41 core/controller tests and the native image-rendering/reopened-conversation workflow. The consistent-current-source full suite at 09:15:53 passes **50 tests**: 41 core/controller and nine native workflows, zero failures/skips. AppIntents metadata, synthetic file-URL sandbox and internal XCTest QoS warnings remain; no clean-warning claim is made. The added same-image reopen assertion passes in the separate 09:23:16 targeted run; this is an extension of the existing test, not a fifty-first unique test. No accepted earlier attachment was resent, and temporary unsent diagnostic drafts were removed.

R13 feasibility was inspected read-only in the authorized Pal test conversation: invoking Reply on the exact MB1001-1657 bubble yields a Reply transcript containing that original prompt and a Reply composer whose help identifies Pal's exact address. Escape restored the ordinary conversation without typing or sending. No message GUID is exposed in that native accessibility identity; this is a native UI probe, not an app-driven reply or database-linkage proof. R13 remains gated.

## October 2 live delivery and subsequent polish

The consolidated canonical Debug build at 09:28:30 passes strict signature verification. Its first launch lost history access after the development signature changed; the existing approval was refreshed and the app reopened with Done/read-only history. No source bundle was rebuilt under a running process. Quick Look in this real build renders the fresh blue/green PNG and a synthetic text file, reopens the same image, and opens the image from its delivered transcript card. The real preview screenshot is `docs/evidence/attachments/quick-look-live-MB1002-0929.png`.

At 09:33 the app submitted two fresh files only to Michael's authorized self-address, with Pal excluded. Both outgoing parts have distinct saved anchors. Messages displays incoming self-copies and Read 9:33 AM. The received image and text content open correctly in native Quick Look. msgblast updates to show both outgoing/incoming cards and its database delivery receipt. This establishes self-address transfer, not new multi-recipient delivery. Earlier MB1001-2025 failures remain Not Delivered and were not retried. Scoped results and actual screenshots are listed in `docs/evidence/live-attachment-delivery-MB1002-0929.json`.

A first new comparison attempt stopped before storing intent because Contacts consent had not been renewed. Searching Michael in the add-agent sheet renewed consent and returned the real matching contact and photo; the preserved self-only draft then submitted successfully as comparison `7AE76A1D-37B4-41F3-A990-C46C2BFB4AB8` at 09:43. The old comparison does not display this new ordinary prompt; Pal's older view remains intact. Attempting a diagnostic follow-up to moved Michael yields the original-context guard, keeps the draft, and leaves the old comparison's follow-up count at five. The diagnostic draft was then removed without sending. Actual late thread retention still needs a native inline reply; no substitute or app-driven reply is claimed.

Switching to Separate windows exposes independent Michael/Pal window identities and a private composer. An exact app-owned state comparison confirms both controlled comparisons retain every member, anchor and follow-up receipt. Pointer movement/reopen and restoration to the preferred joined layout were interrupted by the screen locking; the temporary separate preference remains to be restored on resume. No successful drag is claimed.

Side-by-side inspection exposed gray letterboxing around landscape photos. The source now sizes transcript photo cards to the thumbnail's aspect ratio within the existing size bounds and crops compact draft previews to their square. First send also requests undetermined Contacts consent in place, holding the busy guard across the await so repeated clicks cannot start duplicate consent/send flows. These later changes are compiled in the isolated app, not yet deployed to the running canonical bundle.

`Test-msgblast-2026.10.02_09-52-32--0700.xcresult` passes 41 core/controller checks. The first two native tests fail to activate the background fixture; read-only console metadata confirms the screen is locked. The run was stopped with exit 75 rather than repeating the activation failure. The final isolated build-for-testing, including conversation screenshot capture, succeeds. This is not another passing full suite or a rendered photo-layout proof. The earlier 50-test result remains the passing full-suite evidence for the preview/transport revision. Unlock was requested; the resumed blocked audit has encountered the lock once. R13's product decision and actual Dock observation remain unanswered.
