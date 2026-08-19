// Shared helpers for check modules. Not itself a check -- verify-build.mjs
// only imports named `run` exports from sibling files that are checks.
import { readFileSync, existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const CHECKS_DIR = path.dirname(fileURLToPath(import.meta.url))
export const SITE_ROOT = path.resolve(CHECKS_DIR, '..', '..')
export const DIST_DIR = path.join(SITE_ROOT, 'dist')
export const DIST_HTML_PATH = path.join(DIST_DIR, 'index.html')

export function readDistHtml() {
  if (!existsSync(DIST_HTML_PATH)) {
    throw new Error(`dist/index.html not found at ${DIST_HTML_PATH} -- run the build first`)
  }
  return readFileSync(DIST_HTML_PATH, 'utf8')
}

// React escapes ", ', &, <, > in text nodes. Entity decoding is load-bearing:
// a raw-substring match on locked copy containing quotes (e.g. the Matthew
// 10:8 line) will false-fail without this.
const ENTITY_PATTERN = /&quot;|&#x27;|&#39;|&amp;|&lt;|&gt;/g
const ENTITY_MAP = {
  '&quot;': '"',
  '&#x27;': "'",
  '&#39;': "'",
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
}

export function decodeHtmlEntities(text) {
  return text.replace(ENTITY_PATTERN, (match) => ENTITY_MAP[match])
}

export function normalizeWhitespace(text) {
  return text.replace(/\s+/g, ' ').trim()
}

export function decodeAndNormalize(text) {
  return normalizeWhitespace(decodeHtmlEntities(text))
}

// For copy that may legitimately be split across sibling inline elements
// (e.g. a styled leading digit in its own <span>), strip tags to plain
// visible text before comparing, rather than requiring one contiguous
// text node in the raw HTML.
export function stripTagsToText(html) {
  return decodeAndNormalize(html.replace(/<[^>]+>/g, ' '))
}

export function pass(message) {
  return { pass: true, message }
}

export function fail(message) {
  return { pass: false, message }
}
