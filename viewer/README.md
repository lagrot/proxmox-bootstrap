# Landet viewer and offline design studies

**Production:** [landet.ostmarken.se](https://landet.ostmarken.se), owner-only
Cloudflare login, two cameras, up to nine clips, and Kök/Sovrum/Örnnästet/Utomhus.
See [deployment operations](../docs/step22d-landet-deployment.md) and
[local development](LOCAL-VIEWER.md).

The rest of this page documents the **offline sample-only Zola studies**. No backend, credentials, live streams, actual
recordings, Home Assistant requests, or Cloudflare route. The two generated
fictional photos are illustrative; clip controls simulate playback of a still
image. All values/history are fictional. Camera labels are provisional.

Two views: **Kameror** (expand images and open twelve sample clips), and
**Temperatur** (four temperatures, three humidities, clickable daily graphs).
The date picker changes fictional history, not recorded sensor data.

## Review offline

Unzip `artifacts/landet-prototype.zip` on your computer, then open `index.html`
in a current browser. Keep its asset directories beside it. No server or login
is needed. Native fullscreen depends on the browser; the enlarged dialog works
without it. `index.html?demo=empty` exercises the no-recordings state.

## Build

Use Zola **0.23.6** (the version verified for this prototype). From the repository
root:

```bash
zola --root viewer build
zola --root viewer check
node viewer/tests/core.cjs
```

Open `viewer/public/index.html` locally after building. Output and artifacts are
ignored. Source PNGs are preserved; Zola generates optimized WebP images.
There are no CDN dependencies, external fonts, or browser API requests.

## Browser verification

With Node.js and `playwright-core` plus its Chromium browser installed in your
development environment:

```bash
node viewer/tests/browser.cjs
```

For an isolated installation, set `PLAYWRIGHT_MODULE` to its absolute package
path and `PLAYWRIGHT_BROWSERS_PATH` to its browser directory. Tests use file URLs,
check desktop/tablet/phone layouts, images, navigation, twelve clips, three
humidity values, history dates (including invalid input), dialog keyboard/focus,
simulated playback/seek, empty state, and absence of external requests/errors.
Screenshots are saved in `artifacts/`. This does not validate real video,
Cloudflare authentication, Safari/iOS fullscreen, or physical touch devices.

Selected design: **TV-fönstret** from round 2. The production implementation
uses static HTML/CSS/JavaScript plus the protected Python backend; Zola remains
a build tool for these studies, not a production runtime dependency. Study
labels/counts are fictional and do not define the final nine-clip/Kök scope.

## Three design experiments

After building Zola, run:

```bash
python3 viewer/experiments/build.py
```

This creates `viewer/artifacts/landet-three-designs.zip`. Extract it locally and
open the top-level `index.html` to compare **Nordisk journal**, **Natt på landet**,
and **Hej, landet!**. Each retains the same sample interactions and content.
The original prototype remains unchanged. To test an individual variant, set
`VIEWER_PAGE` to its generated HTML path when running `tests/browser.cjs`;
`DESIGN_NAME` optionally prefixes screenshot filenames.

## Round 2: different information architectures

The first three alternatives reused the same page structure and were rejected
as theme variations. The second round has independent page compositions and
interaction code (shared sample-data helpers only):

- **Huset:** schematic spatial house with room/history buttons, garden sensor,
  camera positions, and a compact recordings contact sheet. The house is
  fictional, not a measured plan of the property.
- **TV-fönstret:** a single selected camera, two explicit channel buttons,
  horizontal recordings reel, visible climate summary, and expandable climate
  panel. History is available from both summary and panel.
- **Dagboken:** vertical recording chronology, camera strip, and sticky climate
  margin on desktop; climate moves before the journal on phone.

From the repository root, after `zola --root viewer build`:

```bash
python3 viewer/experiments/round2/build.py
node viewer/tests/studies.cjs
```

Browser tests use the same Playwright setup described above. They verify all
three layouts at desktop/tablet/phone sizes, twelve clips, image loading,
date changes and invalid dates, media dialogs, simulated playback/seek,
keyboard dismissal/focus, TV channel/panel changes, and zero external requests.
Screenshots go to `viewer/artifacts/v2-*.png`.

Extract `viewer/artifacts/landet-three-designs-v2.zip` locally and open its
root `index.html`. The original prototype and first studies remain available.
