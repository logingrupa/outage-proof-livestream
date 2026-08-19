import { readDistHtml, pass, fail } from './_shared.mjs'
import { meta } from '../../src/copy/en/meta.ts'

export const name = 'headMetaComplete'

const REQUIRED_SNIPPETS = [
  '<title>',
  '<meta name="description"',
  '<meta name="robots"',
  `<link rel="canonical" href="${meta.siteUrl}"`,
  'property="og:title"',
  'property="og:description"',
  'property="og:type"',
  'property="og:url"',
  'property="og:site_name"',
  'name="twitter:card"',
  '<html lang="en"',
]

export function run() {
  const html = readDistHtml()
  const missing = REQUIRED_SNIPPETS.filter((snippet) => !html.includes(snippet))
  if (missing.length > 0) {
    return fail(`missing head elements: ${missing.join(', ')}`)
  }
  return pass('title, description, robots, canonical, OG, Twitter, and html[lang] all present')
}
