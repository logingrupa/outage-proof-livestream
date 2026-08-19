#!/usr/bin/env node
// Vite's documented two-build SSR/prerender recipe (RESEARCH.md D-09): read
// the client build's shell HTML, render the app to a string with the server
// build, splice the rendered markup into the empty root element, then fold
// dist/client/* up into dist/ and drop dist/server. Safely re-runnable over
// a freshly rebuilt dist -- `npm run build:client` always empties
// dist/client first, so a stale prior run never lingers.
import { existsSync, readFileSync, writeFileSync, rmSync, readdirSync, renameSync, mkdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const SITE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const DIST_DIR = path.join(SITE_ROOT, 'dist')
const CLIENT_DIR = path.join(DIST_DIR, 'client')
const SERVER_DIR = path.join(DIST_DIR, 'server')
const CLIENT_HTML_PATH = path.join(CLIENT_DIR, 'index.html')
const SERVER_ENTRY_PATH = path.join(SERVER_DIR, 'entry-server.js')
const ROOT_PLACEHOLDER = '<div id="root"></div>'
// Matches the whole `<!--GSD_STRUCTURED_DATA_PLACEHOLDER: ... -->` comment in
// index.html regardless of internal whitespace/line-wrapping, so an editor
// reflow of the explanatory text never silently breaks this splice.
const STRUCTURED_DATA_PLACEHOLDER_PATTERN = /<!--GSD_STRUCTURED_DATA_PLACEHOLDER:[\s\S]*?-->/

function assertServerBuildExists() {
  if (!existsSync(SERVER_ENTRY_PATH)) {
    throw new Error(
      `${SERVER_ENTRY_PATH} not found -- run "npm run build:server" before prerendering.`,
    )
  }
}

function assertClientBuildExists() {
  if (!existsSync(CLIENT_HTML_PATH)) {
    throw new Error(
      `${CLIENT_HTML_PATH} not found -- run "npm run build:client" before prerendering.`,
    )
  }
}

async function streamToString(nodeReadableStream) {
  const chunks = []
  for await (const chunk of nodeReadableStream) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
  }
  return Buffer.concat(chunks).toString('utf8')
}

async function loadServerEntryModule() {
  return import(pathToFileURL(SERVER_ENTRY_PATH).href)
}

async function renderAppMarkup(serverEntryModule) {
  const stream = await serverEntryModule.renderPageToStream()
  const markup = await streamToString(stream)
  if (markup.trim().length === 0) {
    throw new Error('prerendered markup was empty -- renderPageToStream() produced no output')
  }
  return markup
}

function spliceMarkupIntoShell(shellHtml, appMarkup) {
  if (!shellHtml.includes(ROOT_PLACEHOLDER)) {
    throw new Error(`expected to find "${ROOT_PLACEHOLDER}" in the client build's index.html`)
  }
  return shellHtml.replace(ROOT_PLACEHOLDER, `<div id="root">${appMarkup}</div>`)
}

// D-20: JSON-LD is no longer rendered by any React component -- it is
// spliced into <head> here, at prerender time. Fails loudly if the
// placeholder comment is missing, exactly like the root-element guard above:
// a silently un-replaced placeholder means a shipped page with no structured
// data, and the whole point of this file is that it never fails quietly.
function spliceStructuredDataIntoHead(shellHtml, structuredDataScriptTags) {
  if (!STRUCTURED_DATA_PLACEHOLDER_PATTERN.test(shellHtml)) {
    throw new Error(
      'expected to find the GSD_STRUCTURED_DATA_PLACEHOLDER comment in the client build\'s index.html <head>',
    )
  }
  return shellHtml.replace(STRUCTURED_DATA_PLACEHOLDER_PATTERN, structuredDataScriptTags)
}

function removeStaleTopLevelDistEntries() {
  // Guards against a stale prior prerender output (e.g. an old top-level
  // dist/index.html or dist/assets/) colliding with the rename below.
  for (const entryName of readdirSync(DIST_DIR)) {
    if (entryName === 'client' || entryName === 'server') continue
    rmSync(path.join(DIST_DIR, entryName), { recursive: true, force: true })
  }
}

function moveClientContentsUpIntoDist() {
  removeStaleTopLevelDistEntries()
  for (const entryName of readdirSync(CLIENT_DIR)) {
    renameSync(path.join(CLIENT_DIR, entryName), path.join(DIST_DIR, entryName))
  }
  rmSync(CLIENT_DIR, { recursive: true, force: true })
}

assertServerBuildExists()
assertClientBuildExists()

const serverEntryModule = await loadServerEntryModule()
const shellHtml = readFileSync(CLIENT_HTML_PATH, 'utf8')
const appMarkup = await renderAppMarkup(serverEntryModule)
const structuredDataScriptTags = serverEntryModule.renderStructuredDataScriptTagsForHead()
const withMarkup = spliceMarkupIntoShell(shellHtml, appMarkup)
const withStructuredData = spliceStructuredDataIntoHead(withMarkup, structuredDataScriptTags)
writeFileSync(CLIENT_HTML_PATH, withStructuredData)

rmSync(SERVER_DIR, { recursive: true, force: true })
mkdirSync(DIST_DIR, { recursive: true })
moveClientContentsUpIntoDist()

console.log('Prerender complete: dist/index.html now contains rendered markup.')
