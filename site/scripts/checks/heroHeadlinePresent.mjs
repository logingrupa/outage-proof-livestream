import { readDistHtml, decodeAndNormalize, pass, fail } from './_shared.mjs'
import { hero } from '../../src/copy/en/hero.ts'

export const name = 'heroHeadlinePresent'

export function run() {
  const html = decodeAndNormalize(readDistHtml())
  const headline = decodeAndNormalize(hero.headline)
  if (!html.includes(headline)) {
    return fail(`locked hero headline not found verbatim in dist/index.html: "${headline}"`)
  }
  return pass('locked hero headline present verbatim')
}
