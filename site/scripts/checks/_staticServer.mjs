// Helper (leading underscore -- verify-build.mjs's discoverCheckFiles skips
// it). Serves dist/ over plain node:http under the Vite base prefix, exactly
// as GitHub Pages will, so subpath-prefixed asset URLs resolve for the
// headless-browser gates in this file's siblings.
import { createServer } from 'node:http'
import { readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { DIST_DIR } from './_shared.mjs'

const BASE_PATH = '/outage-proof-livestream/'

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml',
  '.json': 'application/json',
}

function contentTypeFor(filePath) {
  return CONTENT_TYPES[path.extname(filePath).toLowerCase()] ?? 'application/octet-stream'
}

async function resolveDistFile(requestPath) {
  const withoutBase = requestPath.startsWith(BASE_PATH)
    ? requestPath.slice(BASE_PATH.length)
    : requestPath.replace(/^\/+/, '')
  let decoded = decodeURIComponent(withoutBase.split('?')[0])
  // "" (the base path itself) or a trailing slash is a directory-index
  // request for the homepage -- not a SPA fallback for an unmatched route,
  // which is the thing this server deliberately refuses to paper over.
  if (decoded === '' || decoded.endsWith('/')) decoded += 'index.html'
  const candidate = path.join(DIST_DIR, decoded)
  // Guard against path traversal escaping DIST_DIR.
  if (!candidate.startsWith(DIST_DIR)) return null
  try {
    const stats = await stat(candidate)
    if (!stats.isFile()) return null
    return candidate
  } catch {
    return null
  }
}

// Starts the server on an ephemeral 127.0.0.1 port. Returns { origin, close }.
export async function startStaticServer() {
  const server = createServer((req, res) => {
    const requestUrl = req.url ?? '/'
    resolveDistFile(requestUrl).then((filePath) => {
      if (!filePath) {
        res.writeHead(404, { 'Content-Type': 'text/plain' })
        res.end(`404 not found: ${requestUrl}`)
        return
      }
      readFile(filePath).then((body) => {
        res.writeHead(200, { 'Content-Type': contentTypeFor(filePath) })
        res.end(body)
      })
    })
  })

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  const origin = `http://127.0.0.1:${address.port}`

  return {
    origin,
    baseUrl: `${origin}${BASE_PATH}`,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  }
}
