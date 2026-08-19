import { readDistHtml, pass, fail } from './_shared.mjs'

export const name = 'asciiBannerSurvivesBuild'

// D-22: the house-style block-character banner, reused verbatim from
// pdfeditor.kingdom.lv/app/ with exactly two substituted lines. Matched on
// distinctive substrings rather than full whitespace-fragile lines -- the
// box-drawing run is unmistakable, and the four attribution/quote lines are
// each checked independently so a partial mangling still fails loudly.
const REQUIRED_SNIPPETS = [
  { label: 'box-drawing block-letter run', pattern: '██╗  ██╗██╗███╗   ██╗ ██████╗' },
  { label: 'Revelation 19:16 attribution', pattern: 'KING OF KINGS AND LORD OF LORDS' },
  { label: 'Matthew 10:8 attribution', pattern: 'Matthew 10:8' },
  { label: 'Spirit and Truth city church attribution', pattern: 'Spirit and Truth city church, Lielv' },
  { label: 'LOGINGRUPA Ltd. attribution', pattern: 'LOGINGRUPA Ltd.' },
  { label: 'D-22 replacement line 1 (project is free)', pattern: 'This service is free because what we were given was free.' },
  { label: 'D-22 replacement line 2 (read the source)', pattern: 'Now read the rest of the source. No trackers, no cookies, nothing phones home.' },
]

export function run() {
  const html = readDistHtml()
  const missing = REQUIRED_SNIPPETS.filter((entry) => !html.includes(entry.pattern)).map((entry) => entry.label)

  if (missing.length > 0) {
    return fail(`banner comment missing from built dist/index.html: ${missing.join(', ')}`)
  }
  return pass('the block-character banner, both attributions, and both D-22 replacement lines all survive verbatim into dist/index.html')
}
