import { readDistHtml, stripTagsToText, pass, fail } from './_shared.mjs'
import { hero } from '../../src/copy/en/hero.ts'

export const name = 'singleLoudCallToAction'

function countOccurrences(haystack, needle) {
  return haystack.split(needle).length - 1
}

export function run() {
  const text = stripTagsToText(readDistHtml())
  const count = countOccurrences(text, hero.primaryCallToAction.label)
  if (count !== 1) {
    return fail(`"${hero.primaryCallToAction.label}" occurs ${count} time(s), expected exactly 1 (D-01)`)
  }
  return pass(`"${hero.primaryCallToAction.label}" occurs exactly once`)
}
