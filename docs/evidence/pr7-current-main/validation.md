# PR7 current-main integration

Captured October 6, 2026 from the resolved merge of PR7 with main at
`37419e1abc55f04ae97a8b1a148bd16a5fbe9522`. This replaces the earlier PR7 captures
for the current New Blast toolbar, first-use sign-in flow, and quiet result UI.

The isolated `com.msgblast.pr7-evidence` app uses the blue demo icon, temporary
state, simulated account status and synthetic replies. Login and Terminal
setup are disabled. No live login, setup, inference, Messages send, Contacts
write, or installed-app replacement was performed for these captures.

Manual checks exercised the four local account rows, OpenClaw setup sheet,
native ChatGPT/Claude submission, New Blast, saved-comparison reopening, and a
follow-up that retained both earlier turns. Successful native replies leave
no persistent success banner. Captures are from macOS 27; they do not prove
macOS 15 runtime behavior. The project retains its macOS 15 deployment target.

`walkthrough.mp4` is an approximately 18-second step-capture sequence assembled
from actual UI screenshots with edited two-second holds. It is not a continuous
recording or a provider latency measurement. The setup sheet is captured as its
own surface. Mobile evidence does not apply to this native macOS app.

Independent read-only review checked account detection/login, CLI resume,
cancellation, draft isolation, persistence, and preparation. Its two merge
errors (a missing method brace and native transcript Codable/Identifiable
conformance) were corrected before these captures. Live CLI login and provider
session creation/resumption remain unverified.

Validation: 128 unit tests passed with no failures or skips, including native
comparison preparation/session restoration and incomplete-request blocking.
AppModel/lifecycle fixtures and 35 release-tooling tests passed. Avatar fixture
updates explicitly await generated image decoding before asserting avatar
state; the focused checks are recorded in the PR description.
