import { readDistHtml, pass, fail } from './_shared.mjs'

export const name = 'noHiddenContentInStaticHtml'

// The prerendered markup must be fully visible to a crawler and to a
// visitor with JavaScript disabled -- reveal-on-scroll (Task 3) and the
// accordion's chevron-icon toggle (Task 4) must only hide DECORATIVE
// elements, never CONTENT, and must do so via attribute-aware parsing --
// a naive substring search false-positives on `class="...hidden..."`
// containing the literal word "hidden" as one token among many.
const TAG_PATTERN = /<([a-z][a-z0-9-]*)((?:\s+[a-zA-Z-:]+(?:="[^"]*"|='[^']*'|=[^\s>]+)?)*)\s*\/?>/gi
const ATTR_PATTERN = /([a-zA-Z-:]+)(?:="([^"]*)"|='([^']*)'|=([^\s>]+))?/g
// Decorative-by-construction: lucide-react icons render as raw <svg>/<path>
// with no meaningful text, never page content.
const DECORATIVE_TAGS = new Set(['svg', 'path'])

function parseAttributes(attrString) {
  const attrs = {}
  let match
  ATTR_PATTERN.lastIndex = 0
  while ((match = ATTR_PATTERN.exec(attrString)) !== null) {
    attrs[match[1].toLowerCase()] = match[2] ?? match[3] ?? match[4] ?? ''
  }
  return attrs
}

export function run() {
  const html = readDistHtml()
  const offenders = []

  for (const tagMatch of html.matchAll(TAG_PATTERN)) {
    const [, tagName, attrString] = tagMatch
    if (DECORATIVE_TAGS.has(tagName.toLowerCase())) continue

    const attrs = parseAttributes(attrString)
    const classTokens = (attrs.class ?? '').split(/\s+/).filter(Boolean)
    const style = attrs.style ?? ''

    if (classTokens.includes('opacity-0')) {
      offenders.push(`<${tagName}> has class="opacity-0"`)
    }
    if (classTokens.includes('hidden')) {
      offenders.push(`<${tagName}> has class="hidden"`)
    }
    if (Object.prototype.hasOwnProperty.call(attrs, 'hidden')) {
      offenders.push(`<${tagName}> has the boolean hidden attribute`)
    }
    if (/visibility\s*:\s*hidden/.test(style)) {
      offenders.push(`<${tagName}> has style="visibility:hidden"`)
    }
  }

  if (offenders.length > 0) {
    return fail(`static HTML hides content via: ${offenders.join(', ')}`)
  }
  return pass('no non-decorative element in the static HTML is hidden via opacity-0, hidden, or visibility:hidden')
}
