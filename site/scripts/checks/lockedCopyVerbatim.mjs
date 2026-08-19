import { readDistHtml, stripTagsToText, decodeAndNormalize, pass, fail } from './_shared.mjs'
import { hero } from '../../src/copy/en/hero.ts'
import { mission } from '../../src/copy/en/mission.ts'

export const name = 'lockedCopyVerbatim'

export function run() {
  const text = stripTagsToText(readDistHtml())
  const lockedStrings = [hero.headline, hero.subheadline, ...mission.lines]

  const missing = lockedStrings.filter((locked) => !text.includes(decodeAndNormalize(locked)))
  if (missing.length > 0) {
    return fail(`locked string(s) not found verbatim: ${missing.join(' || ')}`)
  }
  return pass('hero headline, hero sub, and all four mission lines present verbatim')
}
