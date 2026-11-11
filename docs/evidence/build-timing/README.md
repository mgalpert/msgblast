# Build timing evidence for PR #118

Terminal captures of the real CI output for the Measure build times run
https://github.com/mgalpert/msgblast/actions/runs/42956316064 at PR head
4b3667479eb4b965587bc88e4ca1826f4e0a9c47, fetched through the GitHub API with
`gh run view` and the run's `msgblast-build-timing-<sha>` artifact. Runner:
GitHub-hosted `xcode-27` image, Xcode 27.0 (27A266a), Apple M1 (Virtual), 3 cores.

- `ci_timing_summary.png`: summary table, slowest type-checks, machine report.
- `ci_timing_log.png`: job log lines with Xcode, CPU, and per-step seconds.
- `ci_build_timing_replay.mp4`: about 36 seconds of the same terminal workflow.
