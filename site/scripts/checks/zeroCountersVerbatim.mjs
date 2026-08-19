import { readDistHtml, stripTagsToText, decodeAndNormalize, pass, fail } from './_shared.mjs'
import { zeroCounters } from '../../src/copy/en/zeroCounters.ts'

export const name = 'zeroCountersVerbatim'

export function run() {
  // Text-only comparison: the leading digit legitimately renders in its own
  // inline element for accent styling, so this must tolerate a tag boundary
  // between "0" and the rest of the string, not just entity decoding.
  const html = stripTagsToText(readDistHtml())
  let searchFrom = 0
  for (const counter of zeroCounters.counters) {
    const normalizedCounter = decodeAndNormalize(counter)
    const foundAt = html.indexOf(normalizedCounter, searchFrom)
    if (foundAt === -1) {
      return fail(`locked zero-counter string not found in order: "${normalizedCounter}"`)
    }
    searchFrom = foundAt + normalizedCounter.length
  }
  return pass('all four locked zero-counter strings present verbatim, in order')
}
