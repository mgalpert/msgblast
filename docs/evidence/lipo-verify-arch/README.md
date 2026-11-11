# lipo -verify_arch evidence (PR #106)

These files are renderings of real terminal output captured on pal's Mac Studio.
They are not screen recordings. That unattended run had no Screen Recording
permission, so the saved logs were shown in a page and captured with Playwright.
The log text is unedited.

- `lipo-verify-arch-before-after.png`: full-page image of both logs.
- `lipo-verify-arch-before-after.webm`: the same page scrolling through both logs.

Both logs come from
`python3 -m unittest discover -s scripts/tests -p test_test_builds.py -v`
with Command Line Tools only (no full Xcode) and system Python 3.9.6.

- Before: origin/main `8fd9191f4838e5764f92330e24d0aa9d4b83451f`. lipo stops with
  `unknown architecture specification flag: <binary> in specifying -verify_arch operation`.
  Result: `Ran 12 tests`, `FAILED (errors=1)`.
- After: PR head `02391275a9504668bf9fd8b29fce5c47420b5741`. Result: `Ran 12 tests`,
  `OK`. The commit that adds this folder changes only these evidence files.

Limits: this is one test file under Python 3.9.6. It is not the pinned Python 3.11
suite, a native Xcode build, or the `validate.yml` run on the `xcode-27` runner.
