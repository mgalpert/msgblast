# Views.swift type-check evidence for PR #119

Captured on the GitHub-hosted `xcode-27` runner (Xcode 27.0 27A266a, Apple M1
Virtual, 3 cores) by the temporary comparison workflow on branch
`cursor/views-typecheck-measure-0ebe`. Before is `main` d71d582; after is the PR.

- `main-window-before-after.png`: main window, Debug build launched with
  `--demo --isolated-demo` (simulated fixture data), run 42961883228.
- `main-window-diff.png`: per-pixel comparison of those captures; 2 of 693,248
  pixels differ, at the sidebar-toggle edge.
- `choose-agents-before-after.png`: "Choose your agents" frames from the
  `OnboardingWorkflowTests` screen recordings (Demo fixture), run 42967535634.
  Only the mouse-cursor positions differ.
- `views_before_after.mp4`: side-by-side recordings of both screens.
