import { readDistHtml, pass, fail } from './_shared.mjs'

export const name = 'structuredDataValid'
const LD_JSON_PATTERN = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g

export function run() {
  const html = readDistHtml()
  const blocks = [...html.matchAll(LD_JSON_PATTERN)].map((match) => match[1])

  if (blocks.length === 0) {
    return fail('no <script type="application/ld+json"> blocks found')
  }

  const types = new Set()
  for (const [index, rawJson] of blocks.entries()) {
    let parsed
    try {
      // The injected markup escapes `<` as `<` (threat T-ug4-04); plain
      // JSON.parse handles that unicode escape natively.
      parsed = JSON.parse(rawJson)
    } catch (error) {
      return fail(`JSON-LD block ${index} failed to parse: ${error instanceof Error ? error.message : String(error)}`)
    }
    const entries = Array.isArray(parsed) ? parsed : [parsed]
    for (const entry of entries) {
      if (entry && typeof entry['@type'] === 'string') {
        types.add(entry['@type'])
      }
    }
  }

  if (!types.has('SoftwareApplication')) {
    return fail(`no JSON-LD block declares @type "SoftwareApplication" (found: ${[...types].join(', ') || 'none'})`)
  }
  return pass(`${blocks.length} JSON-LD block(s) parse cleanly and include SoftwareApplication`)
}
