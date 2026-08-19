import { readDistHtml, pass, fail } from './_shared.mjs'
import { hero } from '../../src/copy/en/hero.ts'

export const name = 'sectionAnchorsPresent'
const REQUIRED_IDS = ['id="problem"', 'id="how-it-works"', 'id="quickstart"']

export function run() {
  const html = readDistHtml()
  const missing = REQUIRED_IDS.filter((id) => !html.includes(id))
  if (missing.length > 0) {
    return fail(`missing section anchors: ${missing.join(', ')}`)
  }

  const heroHref = hero.primaryCallToAction.href
  if (!heroHref.startsWith('#') || !REQUIRED_IDS.includes(`id="${heroHref.slice(1)}"`)) {
    return fail(`hero CTA href "${heroHref}" does not resolve to one of the required section anchors`)
  }

  return pass('problem, how-it-works, and quickstart anchors present; hero CTA resolves to one of them')
}
