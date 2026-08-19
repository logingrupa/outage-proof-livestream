import { readDistHtml, pass, fail } from './_shared.mjs'

export const name = 'prerenderRan'

export function run() {
  const html = readDistHtml()
  if (html.includes('<div id="root"></div>')) {
    return fail('dist/index.html has an empty root element -- prerender did not run')
  }
  return pass('root element is populated with prerendered markup')
}
