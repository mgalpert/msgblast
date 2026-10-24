# PR 79 evidence

Evidence-SHA: 2ba70098608d027192235630ab2fc2ca7bba8ee9
Base-SHA: b8bf6143f4875a1b6de9372335bf77dae8035f75

The numbered screenshots show the actual isolated msgblast Demo built from the committed Evidence-SHA. Permissions, installations and connection results are simulated. No provider was contacted and no OS access changed.

The 44-second continuous window-only recording shows simulated permission gating, ChatGPT/Dots selection, connection results and Start chatting. No audio; scaled to fit, with no timing edits. Video: https://github.com/user-attachments/assets/72b4da13-8e77-4c73-891c-127f6764cd21

The two live success screenshots show scoped msgblast Dev panes on Pals Studio with our test prompts and observed replies. That debug build reports ad1a243 plus working-tree edits; the three changed ChatGPT/Dots source files were hash-checked against Evidence-SHA. These are supplemental live checks, not captures of the newly committed Dev binary. ChatGPT new-chat, follow-up after switching away, and two Dots turns passed. No private desktop or accessibility dumps are included.

Validation: 310 affected native tests and 25 packaging/tooling tests passed on Evidence-SHA. Dev and Demo packaged with isolated profiles, updates disabled, and signature checks. Earlier other-provider live checks and Sparkle fixtures are described separately in the PR; they were not rerun on this binary.

## SHA-256

- `02-permissions-partial.png`: `0c87373f6706706b40d3cecd38f3c64a2eb48c726fe75bab4ee04e30b81aada7`
- `03-permissions-ready.png`: `84fb1a912c03fa6a91f266f9c2a55bbb0b12e5a8cf4ebe80230e9ed2079e0735`
- `05-chooser-selected.png`: `f0b487aba88feb063602ad5bbd95680a7af8bbef2e34fbe33b8862fa48c81511`
- `07-connections-ready.png`: `cc4a5d87009c3a48226a50e6e6b60bf217d7b3adc175be9ea0adecc8c9d3c90f`
- `chatgpt-live-success.png`: `6f13f1fdc017790192c7629db07d9614edaf50a6466080331920e3146621583c`
- `dots-live-success.png`: `988e0b35d751f00c527943c4bc9dc9f6e36bfde1bbfa033e51e778408b35f2ec`
- `onboarding.mp4`: `151dab0b0fe101649307f0f0287d187d91f3fdd4eb5cb5962ec005d28a8b32da`
