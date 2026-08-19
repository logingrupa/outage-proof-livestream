import { readDistHtml, pass, fail } from './_shared.mjs'

export const name = 'sectionOrder'
// Locked order (D-06), extended to eleven by D-24: `dashboard` inserted
// between `zero-counters` and `quickstart` so the real evidence lands
// immediately before the conversion moment.
const ORDERED_IDS = [
  'hero',
  'problem',
  'how-it-works',
  'zero-counters',
  'dashboard',
  'quickstart',
  'transport',
  'requirements',
  'faq',
  'mission',
  'footer',
]

export function run() {
  const html = readDistHtml()
  const positions = ORDERED_IDS.map((id) => ({ id, index: html.indexOf(`id="${id}"`) }))

  const missing = positions.filter((entry) => entry.index === -1)
  if (missing.length > 0) {
    return fail(`missing section anchors: ${missing.map((entry) => entry.id).join(', ')}`)
  }

  for (let i = 1; i < positions.length; i++) {
    if (positions[i].index <= positions[i - 1].index) {
      return fail(
        `section "${positions[i].id}" does not appear after "${positions[i - 1].id}" in document order`,
      )
    }
  }

  return pass(`all eleven sections appear in the locked order: ${ORDERED_IDS.join(' -> ')}`)
}
