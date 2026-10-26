# Multiple provider accounts

Research checked 2026-10-26. Provider features can change; the links below are
primary sources, and documentation is distinguished from a tested integration.

## Recommended approach

Use a named, persistent website profile for each account, such as **ChatGPT Work**
and **ChatGPT Personal**. This builds on msgblast’s existing WebKit stores and
saved agent identities. Each account can be selected independently in a comparison.
No provider credentials are copied into msgblast’s account registry.

[WebKit’s profile API](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/)
provides separate persistent website data stores identified by saved UUIDs. Each
account uses its own store, so its website cookies and login storage are isolated.
msgblast also keeps each agent’s drafts, conversation addresses and send receipts
in its own state file. Existing agents and shared-sign-in copies retain their IDs.

Duplicating an installed Mac app is not a reliable account-isolation mechanism:
a second bundle can still use the same application support files, Keychain entries
and app-owned authentication. That is an engineering assessment, not a claim that
every provider uses the same storage. Rewriting bundle identifiers or signing
third-party apps would also complicate updates. Provider-native account switching
is useful for manual use, but a shared active account is insufficient to pin two
comparison recipients to distinct accounts simultaneously.

## Provider findings

| Provider | Officially documented support | Consequence for msgblast |
| --- | --- | --- |
| ChatGPT | [Web account switching](https://help.openai.com/en/articles/20001068-using-multiple-accounts-with-account-switching) supports two signed-in accounts, with one active at a time. The article identifies web availability; do not assume the Mac app has the same capability. | Separate website profiles keep both comparison recipients independently signed in. |
| Claude | [Account switching](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account) is documented for personal and Team/Enterprise accounts tied to the same email. This does not establish saved switching between arbitrary different-email Mac logins. | Separate website profiles cover the work/personal, different-email case without changing Claude Desktop’s account. |
| Google / Gemini | [Google’s account menu](https://support.google.com/accounts/answer/1721977) supports multiple logins and account switching. This is Google account documentation, not verification of a Gemini Mac app switcher. | This PR does not enable the currently deferred Gemini integration or add a new Gemini website adapter. |
| X / Grok | [X documents multiple accounts](https://help.x.com/en/managing-your-account/managing-multiple-x-accounts) on its web and mobile clients. That is not proof of a standalone Grok app switcher. | Grok’s existing website adapter can use separate profiles. Grok Bot connections retain their own separate setup. |
| Muse, Dots, rabbit OS3, Hark, Wabi | A provider-native multi-account switcher was not verified in the official documentation consulted. Absence of verified documentation is not proof of lack of support. | Muse’s existing website adapter supports extra profiles. Dots, rabbit OS3, Hark, and Wabi keep their existing integration limits. |

## Using accounts

1. Open **Settings → Web agents**, then **Add ChatGPT account…**, **Add Claude
   account…**, **Add Muse account…**, or **Add Grok account…**.
2. Give it a recognizable label. Choose **Sign in…** beside that account and sign
   in using the provider’s website. The name is your label; msgblast does not
   verify the signed-in email. Check the website’s account menu before sending.
3. Select the named tile in the agent grid when you want to include that account.
   Adding an account does not automatically select it or send anything.
4. Disable an account in Settings to stop using it without deleting its saved
   state. Rename a named account there or through its tile’s context menu.

A website tile also offers **Add another account…**. ChatGPT, Claude and Muse Mac
app tiles offer **Add website account…**, opening the website’s separate sign-in.
These profiles do not change the account selected in the provider’s installed app.

**Duplicate agent…** remains available for another conversation using the same
sign-in. Its separate-account toggle remains compatible with existing workflows.
Signing out affects copies that deliberately share a website profile, but not
other profiles. Switching identities inside an existing profile changes that
profile’s active identity; use a new profile to preserve a stable account boundary.
Browser-import and provider login restrictions still apply; a separate profile
does not bypass an organization’s SSO policy or a provider’s embedded-browser rules.

## Verification boundaries

Native regression coverage uses synthetic cookies in real persistent WebKit
stores to verify shared-login copies, isolated profiles, independent logout and
restored account state. It does not authenticate real provider accounts.
Demo UI coverage uses simulated pages. Functional Dev checks open real provider
sign-in pages without sending prompts, moving credentials or changing installed
provider apps. A successful login by the account owner is still needed to verify
that provider’s authentication flow under their organization’s policy.
