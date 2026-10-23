# Native-agent onboarding evidence

App source: ebdb6801a6f941a5833b2d5278cdb83707bd4547.

All uploaded pictures show the actual blue msgblast Demo app built from this committed source. Permissions, app installation, accounts, bot/model choices and replies are simulated. No installed provider app was contacted and no OS access was granted or reset. The app uses its isolated temporary Demo store. The Debug preview settings used to expose onboarding and simulated denied permissions are recorded in evidence-metadata.json.

The 32-second MP4 is an edited sequence of exact native screenshots with labels outside the captured window. It is not continuous screen recording and has no audio. It shows blocked permissions, one complete app-access group, the native chooser, pending connection gating, bot/model/thinking/Task choices, and a three-agent fixture comparison. The video was fully decoded and a sample frame inspected. Still images retain the original screenshot bytes. No mobile layout applies to this native macOS UI.

Validation on this source: 187 affected native adapter tests, 25 packaging Python tests, all five real Sparkle updater fixture cases, controller fixtures, and embedded host-attribution/private-socket checks passed locally. CI on this revision is separate. Local fixtures cannot prove provider delivery or fresh TCC grants.

Live Dev checks separately verified first-click connections for Muse, Gemini, Wabi, Claude and Grok Bot with their apps closed. Private account screenshots are deliberately excluded from this public evidence. Current live ChatGPT/Dots verification remains unavailable because computer use refused their shared application. Historical send/reply results are not presented as new validation.
