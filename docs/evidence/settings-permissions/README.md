# Settings permissions evidence

Application source: `9fffacd86138231792d5375d0335f3d76eca1cde`.
Original task base: `b0559167c53b9a9f004923ceb8ce8a8cc7dd6f80`.
Integrated main: `62610406a631135fbf7ad28596e99320a19436ea`.
The evidence-only follow-up commit changes no application or test source.

The final application source was committed before building. A Git archive of
that revision supplied the isolated blue-green development build; only its icon
resource was replaced with the saved Dev artwork. The blue Demo build used the
same committed revision. The canonical green source artwork remained unchanged.
Both packaged apps passed strict, deep signature verification and compiled-icon
classification. They have isolated support directories and disabled updates.
This source PR does not publish an app update.

| Capture | What it shows |
| --- | --- |
| 01-before-settings.png | Native baseline Demo Settings without a permissions table. Built source `f8fd41d4ace12481d969a732577ba37f21e649b3`; Settings source matches the original task base. |
| 02-live-permissions.png | Final live Dev shows Messages access Off, Contacts Not requested, and sending Not requested, with available actions. |
| 03-demo-permissions.png | Final Demo shows simulated Allowed statuses and the visible simulation notice. |
| 04-full-disk-access.png | Live Messages recovery opened the actual Full Disk Access pane. |
| 05-contacts-settings.png | Demo Contacts Manage opened the actual Contacts pane. |
| 06-automation-settings.png | Demo Sending Messages Manage opened the actual Automation pane. |
| 07-live-refresh.png | Live Settings on return shows a fresh Allowed history result while Contacts and sending remain Not requested. |
| workflow.mp4 | 33-second edited sequence of these native captures, showing the actions and their destinations. |

Screenshots are cropped to the changed feature or destination heading and
explanation. The OS account sidebar and app inventories are excluded. Raw
captures remain local and ignored. UI text and controls were not edited.
Video uses repeated still frames, outside-UI captions, scaling/padding, and
shortened timing. It is an edited screenshot sequence, not continuous capture
or a real-time permission measurement. No mobile surface changed.

The agent did not change any system permission, send real messages, write
Contacts, make provider requests, or reset TCC. History access changed from Off
to Allowed between observed checks without the agent toggling a system switch;
these captures do not establish why, a first-time consent result, or production
permission retention. The Demo statuses are simulated; its Manage buttons open
real OS panes without changing their switches.

Validation and review dispositions are recorded in `validation.json` and
`review-dispositions.json`. `capture-manifest.json` records source/media hashes,
compiled preview metadata, and demonstration limits. The local UI runner failed
to initialize automation mode before assertions; compilation and manual native
checks are reported separately from an executed UI test.
