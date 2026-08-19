import { readDistHtml, pass, fail } from './_shared.mjs'

export const name = 'headingHierarchy'
const HEADING_PATTERN = /<h([1-6])[\s>]/g

function extractHeadingLevels(html) {
  return [...html.matchAll(HEADING_PATTERN)].map((match) => Number(match[1]))
}

export function run() {
  const levels = extractHeadingLevels(readDistHtml())

  const h1Count = levels.filter((level) => level === 1).length
  if (h1Count !== 1) {
    return fail(`expected exactly one <h1>, found ${h1Count}`)
  }
  if (levels[0] !== 1) {
    return fail(`the first heading in the document is <h${levels[0]}>, not <h1>`)
  }

  for (let i = 1; i < levels.length; i++) {
    if (levels[i] > levels[i - 1] + 1) {
      return fail(`heading level skipped: <h${levels[i - 1]}> is immediately followed by <h${levels[i]}>`)
    }
  }

  return pass('exactly one <h1>, it is the first heading, and no heading level is skipped')
}
