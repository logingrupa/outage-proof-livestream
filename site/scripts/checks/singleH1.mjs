import { readDistHtml, pass, fail } from './_shared.mjs'

export const name = 'singleH1'

export function run() {
  const html = readDistHtml()
  const matches = html.match(/<h1[\s>]/g) ?? []
  if (matches.length !== 1) {
    return fail(`expected exactly one <h1> in dist/index.html, found ${matches.length}`)
  }
  return pass('exactly one <h1> present')
}
