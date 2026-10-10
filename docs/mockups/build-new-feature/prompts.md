# Image generation prompts

Generated with the built-in imagegen tool. The inputs were the repository's
`docs/images/readme/choose-agents.jpg` style reference and
`docs/images/readme/msgblast-icon.png` branding reference. The copied state used
the generated invitation as an edit target.

## Menu

```text
Use case: ui-mockup
Asset type: high-fidelity design concept of the native macOS msgblast application menu, feature entry point.
Primary request: Show a macOS menu bar with the "msgblast" application menu open and the new menu command "Build a New Feature…" highlighted in native macOS blue. This command will open the separate invitation window. One clear view; no second panel.
Input images: Image 1 is a style reference only for the existing dark-mode msgblast app window in the background. Image 2 is the actual green msgblast icon as branding reference; do not redesign it or introduce another logo.
Scene: A straight-on, tightly framed dark-mode macOS desktop screenshot-style mockup. A subtle charcoal desktop, the menu bar at the very top, and part of the app window behind. No device frames, perspective, promotional lighting, annotations, or fake webpage.
Composition: Landscape around 1400x1000. The open dropdown in upper-left is the focal point, large enough to read at a glance; background msgblast window is muted but has authentic native window chrome and sidebar. Do not include private conversation text; show a neutral empty composer and sidebar labels "Agents", "Discover", "Comparisons", "New Blast".
Menu bar exact labels in order: Apple symbol, bold "msgblast", "File", "Edit", "View", "Comparisons", "Window", "Help".
Dropdown: macOS dark translucent charcoal rounded menu, authentic Apple spacing, SF Pro typography, modest shadow. Menu rows verbatim:
"About msgblast"
"Send Feedback…"
"Build a New Feature…" [this row alone highlighted blue with white text, pointer hovering over it]
"Check for Updates…"
separator
"Settings…" [right aligned shortcut ⌘,]
separator
"Services" [right-facing submenu chevron]
separator
"Hide msgblast" [right aligned shortcut ⌘H]
"Hide Others" [right aligned shortcut ⌥⌘H]
"Show All" [muted disabled]
separator
"Quit msgblast" [right aligned shortcut ⌘Q]
Constraints: Faithful native macOS desktop UI, no nested submenu for Build a New Feature, no shortcut invented for it, no body text or extra buttons added to dropdown. Exact casing of msgblast. This is a UI design proposal, not PR evidence.
```

## Invitation

```text
Use case: ui-mockup
Asset type: high-fidelity macOS desktop app feature invitation window, design concept for msgblast.
Primary request: Generate one crisp, straight-on, production-plausible native macOS dark-mode window titled "Build a New Feature". This is a proposed screen, not an implemented app screenshot. It invites a user to copy a useful prompt to their coding agent, fork the public repo, build a feature for themselves, and contribute it.
Input images: Image 1 is a visual style reference only: msgblast native dark interface. Image 2 is the actual green msgblast app icon, supporting branding insert; preserve its white stacked speech bubbles on vivid green, do not redesign it. Do not reproduce the agents picker from Image 1.
Composition: One complete window centered on a plain dark neutral background. Window approximately 700 logical pixels wide by 850 tall, rendered large enough for every word to be readable. Authentic traffic-light buttons, native title bar, restrained 12px corner radius, very subtle shadow, SF Pro system typography, dark charcoal window (#262626), slightly deeper text fields (#1c1c1e), thin gray separators, native blue primary action. Clean aligned left margins, practical padding, no large ornamental illustrations.
Content from top to bottom:
- Standard title bar text "Build a New Feature".
- A small 48px genuine msgblast green app icon beside a large warm headline, verbatim "Excited to see what you build."
- Secondary sentence verbatim "Make msgblast work the way you want. Build it for yourself, then share it with everyone."
- Compact repository row with GitHub symbol, label "Public GitHub repository", and blue clickable-looking text "github.com/mgalpert/msgblast ↗".
- Form label "What would you like to build?" and an empty rounded two-line text input with muted placeholder "e.g. Pin my favorite comparisons". A subtle "Optional — you can add your idea in your coding agent." hint beneath it.
- A compact horizontal three-step row: "1  Fork the repo" / "2  Build for yourself" / "3  Share a pull request". Use restrained outlined numbered circles and no large cards.
- Label "Prompt for your coding agent". Below it, a large inset selectable text preview with these exact paragraphs in small but comfortably readable monospaced text:
"I'm using msgblast and want to build a new feature.

My idea: [Describe your feature here]

Fork https://github.com/mgalpert/msgblast and clone my fork locally. Read AGENTS.md and the build guide. Implement my idea and help me run my own build.

Use the Demo app with sample data to test and record the feature. Prepare a pull request with a clear description, screenshots, and a short video."
- Under the preview a small secondary link "Build guide ↗" and adjacent gray text "Mac + Xcode required to run the app."
- Bottom footer separated by a thin rule. Left aligned muted text "Pull requests are reviewed before they reach everyone." Right aligned prominent native blue button with clipboard symbol and exact label "Copy Prompt". Ensure footer not cramped; helper may wrap.
Constraints: This is a friendly practical native Mac utility screen. All specified text rendered verbatim, accurate casing "msgblast". Show only one window, no phone, no browser UI, no arrows or annotations around the image, no device bezel, no marketing mockup, no invented controls, no fake implemented feature behavior. No app version or build number.
```

## Copied state

```text
Use case: ui-mockup
Asset type: exact next interaction state of the existing msgblast "Build a New Feature" window.
Input images: Image 1 is the EDIT TARGET, the approved invitation window design. Keep its composition, exact dimensions, native dark macOS chrome, icon, type, colors, title, repository link, step row, build guide and all other copy unchanged.
Primary request: Show the state immediately after the user enters a feature idea and presses Copy Prompt. Make only these related changes:
1. In the existing "What would you like to build?" text input, replace its muted placeholder with actual white user-entered text "Let me pin my favorite comparisons to the sidebar."
2. In the prompt preview, replace "My idea: [Describe your feature here]" with "My idea: Let me pin my favorite comparisons to the sidebar." Keep the other preview paragraphs verbatim.
3. Change the blue primary button label from "Copy Prompt" to "Copied" with a white checkmark.
4. Add a restrained confirmation line directly above the footer separator, verbatim "Prompt copied. Paste it into your coding agent to get started." Use small readable secondary text and a subtle checkmark. If needed, use the existing bottom padding so the window geometry stays unchanged.
Constraints: This is a proposed UI state, not implementation evidence. No new modal, no toast overlay, no browser, no coding-agent screen, no loader, no send action, no private messages. Preserve all other content and layout.
```
