import { existsSync, statSync } from 'node:fs'
import path from 'node:path'
import { readDistHtml, DIST_DIR, pass, fail } from './_shared.mjs'

export const name = 'screenshotAssetsResolve'
const BASE_PATH = '/outage-proof-livestream/'
// Matches src="..." and every URL inside a srcset="url w, url w, ..." list.
const SRC_PATTERN = /\s(?:src|srcset)="([^"]+)"/g

function extractCandidateUrls(html) {
  const urls = []
  for (const match of html.matchAll(SRC_PATTERN)) {
    for (const entry of match[1].split(',')) {
      const url = entry.trim().split(/\s+/)[0]
      if (url) urls.push(url)
    }
  }
  return urls
}

function resolveToDistFile(url) {
  if (!url.startsWith(BASE_PATH)) return null
  return path.join(DIST_DIR, url.slice(BASE_PATH.length))
}

// This is the gate that makes "a missing format is fine, a 404 is not"
// enforceable (X5Q-09iv): every src/srcset URL in the built HTML must
// resolve to a real, non-empty file inside dist/.
export function run() {
  const html = readDistHtml()
  const urls = [...new Set(extractCandidateUrls(html))]
  const offenders = []

  for (const url of urls) {
    const filePath = resolveToDistFile(url)
    if (!filePath) continue // external or root-relative asset outside the subpath -- not this gate's concern
    if (!existsSync(filePath)) {
      offenders.push(`${url} -- no file at ${filePath}`)
      continue
    }
    if (statSync(filePath).size === 0) {
      offenders.push(`${url} -- file exists but is zero bytes`)
    }
  }

  if (offenders.length > 0) {
    return fail(`image URL(s) do not resolve to a real file in dist/: ${offenders.join(' | ')}`)
  }
  return pass(`all ${urls.length} src/srcset URL(s) resolve to non-empty files in dist/`)
}
