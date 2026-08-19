import { readDistHtml, pass, fail } from './_shared.mjs'

export const name = 'basePathApplied'
const EXPECTED_ASSET_PREFIX = '/outage-proof-livestream/assets/'

export function run() {
  const html = readDistHtml()
  if (!html.includes(EXPECTED_ASSET_PREFIX)) {
    return fail(`no asset URL found with the expected subpath prefix "${EXPECTED_ASSET_PREFIX}" -- check vite.config.ts \`base\``)
  }
  return pass(`asset URLs carry the "${EXPECTED_ASSET_PREFIX}" subpath prefix`)
}
