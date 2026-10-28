# Release graphic builder

Create an editable 4:5 release graphic and export it as a 1120 × 1400 PNG. The
example text describes an earlier release; replace it with highlights verified
against the release notes for the version being announced.

From the repository root, run:

```sh
python3 -m http.server 8369 --bind 127.0.0.1 --directory tools/release-graphic
```

Open `http://127.0.0.1:8369/`. Edit the headline, website and highlights; add,
remove or reorder lines; and choose an icon for each fixed position. Click
**Download PNG** to save the graphic. A browser keeps changes in local storage
for this address, and **Reset** restores the example. Text and exported images
stay on your machine; the builder uses no remote service.

The icons are derived from the app's bundled onboarding assets, with the macOS
Messages icon included as a choice. Update the local copies when the source
artwork changes. The picker lists bundled artwork; it cannot include custom
contact images discovered on an individual's Mac.
