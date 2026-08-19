import type { SiteCopy } from '@/copy/types'
import { buildStructuredData } from '@/seo/structuredData'

// Content is a build-time constant from the copy dictionary; no user input
// reaches it. `<` is escaped to `<` so a `</script>` breakout inside a
// serialised string is impossible (threat T-ug4-04 / T-x5q-02). Moved here
// verbatim from the deleted StructuredData.tsx -- same behaviour, now called
// at prerender time instead of by a rendered React component (D-20).
function serializeForScriptTag(data: unknown): string {
  return JSON.stringify(data).replace(/</g, '\\u003c')
}

// Pure: takes the copy object, builds the structured-data blocks, and
// returns one string of <script type="application/ld+json"> tags joined by
// a newline, ready to splice into <head>. The opening tag is spelled exactly
// as structuredDataValid.mjs and faqStructuredDataMatchesVisible.mjs expect.
export function renderStructuredDataScriptTags(copy: SiteCopy): string {
  const blocks = buildStructuredData(copy)
  return blocks
    .map((block) => `<script type="application/ld+json">${serializeForScriptTag(block)}</script>`)
    .join('\n')
}
