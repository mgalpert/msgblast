# Onboarding login fix

After captures are native macOS CUA screenshots from application source `45b3ff886791990b607b877795bf33364dfde0e1`. Before captures come from the previous Dev/Demo application source `ecbf3f9dce67ec05fbdf8e263c06b6042f064dbf`. The subsequent evidence commit changes only this directory; app, tests, and release notes are unchanged.

The blue Demo uses simulated accounts, Contacts, permissions, and conversations. Its onboarding preview intentionally waits for Continue so each screen can be inspected. The screenshots verify the removal of generic captions and Check again, the signed-out gate, signed-in recognition, grouped contact setup, and retained feedback menu illustration. They do not prove live authentication or permissions.

The two `live-dev-*` captures come from the blue-green functional Dev app using the user's existing setup and Muse login, without demo arguments. Clicking Continue setup automatically advanced past Muse to grouped Messages; no Muse Continue or Check again click was used. The existing user login and choices were preserved. Only the picker and the non-sensitive permission setup result were captured; no live chat, contact addresses, or credential details are included. Messages/Contacts permissions remain unverified and must be checked before the pending production release.

The 18-second video is an edited sequence of actual screenshots around native clicks with repeated frames, scaling/padding, and explanatory labels; it is not a continuous recording or real-time login timing. The Demo and live Dev scenes are labeled separately. No mobile UI changed. No messages were sent, Contacts written, or permission grants made.
