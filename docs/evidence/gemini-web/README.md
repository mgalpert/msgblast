# Gemini website onboarding and shared prompts

Tested app source: `d3cde0a50a1e8bdf6f693a0b5e46acd605c1d4c6`.
Base: `b8bf6143f4875a1b6de9372335bf77dae8035f75`.
Captured October 18, 2026. Subsequent evidence-only commits do not change app code.

## Native Demo evidence

The packaged blue **msgblast Demo** was rebuilt from verified committed source,
with production updates and telemetry disabled, then exercised in a dedicated
macOS 26.5.2 guest. Existing apps and profiles were retained. The run used a new
isolated fixture profile and simulated accounts, prompts, replies, and thread IDs.
It did not send real Messages, write Contacts, or call a live provider.

- `onboarding.png`: Gemini selected in Apps onboarding, using its official icon.
- `separate-thread.png`: a second comparison has its own Gemini thread and reply.
- `restored-thread.png`: reopening the first comparison restores its original
  thread and follow-up, without the second comparison's messages.
- `shared-prompt.mp4`: actual native screen recording showing a shared follow-up
  entering Gemini and its simulated reply. The 32-second excerpt trims the
  beginning and end; playback speed and interaction timing are unchanged.

The screenshots show the changed app, not the live Google website. The local
fixture includes a second editable clipboard element to exercise precise editor
selection; its appearance is not a reproduction of Google's interface.

## Validation

Xcode 27 built the native app and the affected unit suites on the dedicated Mac.
Preview packaging verified the blue compiled icon and strict ad-hoc signatures.
Project regeneration produced no project-file changes because icons are already
included through the existing resource folder.

The committed-source run exercised `WebServiceTests`, `MultiWebAgentTests`,
`PersonalAgentTests`, and `WebAgentInstanceTests`: **166/167 passed**. The unchanged
`testDotsSavesRenderedAvatarUpdatesItAndClearsOnSignOut` failed its animated sprite
color assertion, then **passed in a focused run with separate derived data**.
It also passed in the first broader run. This is not a clean full-suite pass.
All three Gemini tests passed in the committed-source run: onboarding/URL identity,
Quill-style send/new-thread/draft behavior, and signed-out/generating readiness.

A separate live browser check verified authenticated prompt submission, a reply,
two distinct `/app/<16-character hex ID>` chats, and reopening the first chat.
It also confirmed the current editor, send, stop, account, and message markup.
Signed-out Gemini permits temporary interaction but warns that chats are not
saved; shared submissions therefore require sign-in.

Live Google authentication, browser-cookie import, and actual Quill submission
inside the app's embedded WKWebView were not verified. Browser checks and native
fixtures do not prove those flows. Gemini CLI remains a separate integration.
