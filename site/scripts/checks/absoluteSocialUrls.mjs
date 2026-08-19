import { readDistHtml, pass, fail } from './_shared.mjs'
import { meta } from '../../src/copy/en/meta.ts'

export const name = 'absoluteSocialUrls'

// Matches <meta property="og:url" content="...">, <link rel="canonical"
// href="...">, etc. -- captures the attribute value following content= or
// href= on the same tag as one of the tracked social/canonical names.
const TRACKED_TAG_PATTERN =
  /<(?:meta|link)[^>]*(?:property|rel|name)="(og:url|og:image|twitter:image|canonical)"[^>]*(?:content|href)="([^"]*)"/g

export function run() {
  const html = readDistHtml()
  const offenders = []
  let match
  while ((match = TRACKED_TAG_PATTERN.exec(html)) !== null) {
    const [, kind, value] = match
    if (!value.startsWith(meta.siteUrl)) {
      offenders.push(`${kind}="${value}"`)
    }
  }

  if (offenders.length > 0) {
    return fail(`values not absolute under "${meta.siteUrl}": ${offenders.join(', ')}`)
  }
  return pass(`every og:url, og:image, twitter:image, and canonical value is absolute under "${meta.siteUrl}"`)
}
