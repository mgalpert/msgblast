# Multiple provider accounts evidence

Captured source: `bc08825772d8bb992f638f74e0c4337fdcbf6c2e`.
The later evidence-only commit does not change executable source.

The blue msgblast Demo build uses `com.msgblast.demo`, simulated website pages
and isolated fixture state. Screenshots show the account creation dialog, named
Work/Personal profiles, the named sign-in pane, and a Claude Mac app tile's
**Add website account…** route opening its website setup overlay. Adding the
Claude profile left its tile **Not selected**.

`add-account.mp4` is a 17-second **step recording assembled from Cua's actual
window captures**, including native click markers. Holds were adjusted for
readability; it is not continuous screen capture. It shows adding ChatGPT Personal
beside ChatGPT Work, opening its named simulated sign-in pane, and returning to
the independent account rows. No website rendering or account result was fabricated.

The blue-green functional candidate is **msgblast Dev build 1**, from the source
above, on an authorized dedicated Apple Silicon Mac running macOS 27.0.1. The
packager fixes the display name to `msgblast Dev`; the build number and source
identify this candidate. The existing Dev bundle identifier, installation path,
support folder and Apple Development designated requirement were preserved.
This local development candidate is not notarized; production updates are disabled.

Functional Dev checks:

- Created ChatGPT Work and ChatGPT Personal using the actual Settings UI.
- Opened the real, unauthenticated ChatGPT website inside the Work profile;
  `dev-guest-page.png` shows the guest page with its Log in button.
- Disabled Work, quit and relaunched Dev, then verified Work remained disabled
  while Personal remained enabled. Both retained separate saved profile IDs and
  remained unselected. Restored Work to enabled after verification.
- Preserved the previous Dev application and a private local state backup.
  The installed production application and its support folder were not replaced.

These checks do not prove authenticated provider login, organization-specific
SSO, real provider logout, delivery, or paid requests. No credentials were entered,
provider apps duplicated, real messages sent, Contacts changed, or permissions
reset. The native cookie regression uses synthetic cookies in real persistent
WebKit stores; Demo sign-in remains a separate simulation.

Native/packaging/tooling validation:
[Validate msgblast source run](https://github.com/mgalpert/msgblast/actions/runs/40398778185).
The new XCTest UI case is authored but was not executed; the changed UI paths
above were exercised manually on the dedicated Mac.
