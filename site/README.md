# outage-proof-livestream site

Marketing site for the [outage-proof-livestream](https://github.com/logingrupa/outage-proof-livestream)
project. React 19 + Vite + Tailwind v4 + shadcn/Radix, prerendered to real
HTML, deployed to GitHub Pages at `https://logingrupa.github.io/outage-proof-livestream/`.

## Local development

```bash
npm install
npm run dev
```

**No JSON-LD (`<script type="application/ld+json">`) on the dev server --
this is expected, not a bug.** Structured data is emitted by
`scripts/prerender.mjs` into a placeholder comment in `<head>`, and
`npm run dev` never runs prerender. JSON-LD is static build-time data; run
`npm run build` and inspect `dist/index.html` (or `npm run preview`) to see
it. React itself never renders a `<script>` element for this any more --
moving it out of the component tree is what fixed a hydration defect this
pattern risked.

## Building

```bash
npm run build
```

This one command chains everything, and a failure anywhere in the chain
fails the whole build rather than shipping something broken:

1. `build:client` -- `vite build` to `dist/client` (the browser bundle).
2. `build:server` -- `vite build --ssr` to `dist/server` (the SSR entry).
3. `prerender` -- `scripts/prerender.mjs` renders the app to a string with
   the server build, splices it into the client build's empty root element,
   then folds `dist/client/*` up into `dist/` (GitHub Pages serves `dist/`
   directly, not a nested subfolder).
4. `verify` -- `scripts/verify-build.mjs` runs every check module under
   `scripts/checks/` against the built `dist/index.html` (prerender sanity,
   locked copy verbatim, section order, the truthfulness gate, and more).
   **The verifier is inside `build`, not a separate CI step** -- there is no
   CI here; the person running `npm run build` locally IS the gate.

`npm run preview` serves the built `dist/` locally at the same subpath, so
you can sanity-check the real output before publishing.

### Two gates launch a real headless browser

`zeroConsoleErrors` and `clipboardPayloadUnchanged` do not just read
`dist/index.html` -- they serve it, open a real Chromium-family browser
headlessly via the DevTools Protocol (Node 24's built-in `WebSocket`, no
Puppeteer/Playwright), and assert on what that browser actually does. They
resolve a browser binary in this order: `$CHROME_PATH`, then the standard
Chrome install path, then the standard Edge install path. If neither exists,
the check FAILS loudly rather than silently skipping -- set `CHROME_PATH` to
a Chromium-family binary if you build somewhere without Chrome or Edge
installed. Both gates spawn a throwaway `--user-data-dir` and tear the
browser process down in a `finally` block; a leaked headless browser on this
project's build machine (the same PC that streams the church service) is
unacceptable.

### The ASCII banner in `index.html` is load-bearing

The block-character banner at the top of `<body>` (the KING OF KINGS art,
the Revelation 19:16 / Matthew 10:8 lines, the attributions) is reused
verbatim from the sibling `pdfeditor.kingdom.lv/app/` project and is proven
to survive into `dist/index.html` by `asciiBannerSurvivesBuild`. **Do not
introduce an HTML minifier or any build option that strips HTML comments**
-- that check exists specifically to catch it if one ever does.

## The subpath `base`

`vite.config.ts` sets `base: '/outage-proof-livestream/'` because this site
is served from a GitHub Pages *project* page
(`https://logingrupa.github.io/outage-proof-livestream/`), not a user/org
root page. If this ever changes:

- The `base` string must match the new path exactly (leading AND trailing
  slash).
- Every hardcoded absolute URL in `src/copy/en/meta.ts` and in the static
  `<meta>`/`<link>` tags in `index.html` (canonical, OG, Twitter) must move
  to the new origin too -- those are intentionally NOT derived from `base`,
  because social scrapers need a real absolute URL, not a relative one.
- Getting `base` wrong does not fail the build -- it produces a blank white
  page in production (every asset 404s against the wrong path). The
  `basePathApplied` check module exists specifically to catch this before
  it ships.

## Publishing (no CI -- this is a manual, deliberate step)

There is no GitHub Actions workflow for this site. GitHub Pages, for the
public repo, is configured to serve from branch `main`, folder `/docs` --
that folder is committed, built HTML, not source.

The publish loop:

```bash
cd site
npm run build                 # 1. build + prerender + verify (must exit 0)
cd ..
pwsh tools/export-public-tree.ps1 -DestinationPath <path> -Force   # 2. sanitized export, includes docs/
# 3. copy/sync the exported tree's docs/ (and any source changes) into
#    the public repo checkout, commit, and push to main
```

`tools/export-public-tree.ps1` copies this `site/` source into the export
tree (minus `node_modules`, `dist`, `.vite`) AND separately copies the
contents of a freshly built `site/dist/` into the export tree's `docs/`
folder -- that `docs/` folder is what GitHub Pages actually serves. If
`site/dist/` has not been built locally, the export script fails loudly
(exit code 3) rather than silently shipping a public repo with no site.
