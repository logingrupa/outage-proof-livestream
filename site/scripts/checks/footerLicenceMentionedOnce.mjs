import { readDistHtml, stripTagsToText, pass, fail } from './_shared.mjs'

export const name = 'footerLicenceMentionedOnce'

const FOOTER_ELEMENT_PATTERN = /<footer[\s>][\s\S]*?<\/footer>/
const LICENCE_IDENTIFIER = 'AGPL-3.0'

// D-26: the footer names the licence exactly once, linked to the repository
// LICENSE file -- extracts the visible text of <footer> and counts.
export function run() {
  const html = readDistHtml()
  const footerMatch = html.match(FOOTER_ELEMENT_PATTERN)
  if (!footerMatch) {
    return fail('no <footer> element found in dist/index.html')
  }

  const footerText = stripTagsToText(footerMatch[0])
  const occurrences = footerText.split(LICENCE_IDENTIFIER).length - 1

  if (occurrences !== 1) {
    return fail(`"${LICENCE_IDENTIFIER}" occurs ${occurrences} time(s) in <footer>, expected exactly 1 (D-26)`)
  }
  return pass(`"${LICENCE_IDENTIFIER}" occurs exactly once in <footer>`)
}
