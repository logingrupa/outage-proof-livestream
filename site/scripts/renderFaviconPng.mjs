#!/usr/bin/env node
// One-shot, manually-run tool (not part of `npm run build`): renders
// public/favicon.png from public/favicon.svg using the same locally
// installed headless Chromium-family browser the build gates use. Re-run
// this whenever favicon.svg's artwork changes. Referenced by a comment in
// favicon.svg itself so the regeneration command is discoverable there.
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { withHeadlessSession } from './checks/_headlessSession.mjs'

const SITE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const SVG_PATH = path.join(SITE_ROOT, 'public', 'favicon.svg')
const PNG_PATH = path.join(SITE_ROOT, 'public', 'favicon.png')
const RENDER_SIZE_PX = 256

function buildWrapperHtml(svgMarkup) {
  return `<!doctype html><html><head><style>
    html,body{margin:0;padding:0;background:transparent;}
    svg{width:${RENDER_SIZE_PX}px;height:${RENDER_SIZE_PX}px;display:block;}
  </style></head><body>${svgMarkup}</body></html>`
}

const svgMarkup = readFileSync(SVG_PATH, 'utf8')
const tempDir = mkdtempSync(path.join(os.tmpdir(), 'gsd-favicon-render-'))
const wrapperPath = path.join(tempDir, 'favicon-wrapper.html')
writeFileSync(wrapperPath, buildWrapperHtml(svgMarkup))

try {
  const pngBase64 = await withHeadlessSession(pathToFileURL(wrapperPath).href, async (session) => {
    const result = await session.send('Page.captureScreenshot', {
      format: 'png',
      clip: { x: 0, y: 0, width: RENDER_SIZE_PX, height: RENDER_SIZE_PX, scale: 1 },
      captureBeyondViewport: true,
    })
    return result.data
  })
  writeFileSync(PNG_PATH, Buffer.from(pngBase64, 'base64'))
  console.log(`Wrote ${PNG_PATH} (${RENDER_SIZE_PX}x${RENDER_SIZE_PX})`)
} finally {
  rmSync(tempDir, { recursive: true, force: true })
}
