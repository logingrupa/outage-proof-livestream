import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { DIST_DIR, pass, fail } from './_shared.mjs'
import { meta } from '../../src/copy/en/meta.ts'

export const name = 'publicFilesPresent'
const REQUIRED_FILES = ['robots.txt', 'sitemap.xml', 'llms.txt', 'favicon.svg']

function extractSitemapLocations(xml) {
  return [...xml.matchAll(/<loc>([^<]*)<\/loc>/g)].map((match) => match[1])
}

function extractMarkdownLinkUrls(markdown) {
  return [...markdown.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)].map((match) => match[1])
}

export function run() {
  const missing = REQUIRED_FILES.filter((fileName) => !existsSync(path.join(DIST_DIR, fileName)))
  if (missing.length > 0) {
    return fail(`missing from dist/: ${missing.join(', ')}`)
  }

  const sitemapXml = readFileSync(path.join(DIST_DIR, 'sitemap.xml'), 'utf8')
  const sitemapUrls = extractSitemapLocations(sitemapXml)
  const relativeSitemapUrls = sitemapUrls.filter((url) => !url.startsWith('http'))
  if (sitemapUrls.length === 0 || relativeSitemapUrls.length > 0) {
    return fail(`sitemap.xml must contain only absolute <loc> URLs; found: ${sitemapUrls.join(', ') || 'none'}`)
  }
  const offSiteSitemapUrls = sitemapUrls.filter((url) => !url.startsWith(meta.siteUrl))
  if (offSiteSitemapUrls.length > 0) {
    return fail(`sitemap.xml has URLs outside "${meta.siteUrl}": ${offSiteSitemapUrls.join(', ')}`)
  }

  const llmsTxt = readFileSync(path.join(DIST_DIR, 'llms.txt'), 'utf8')
  const llmsUrls = extractMarkdownLinkUrls(llmsTxt)
  const relativeLlmsUrls = llmsUrls.filter((url) => !url.startsWith('http'))
  if (llmsUrls.length === 0 || relativeLlmsUrls.length > 0) {
    return fail(`llms.txt must contain only absolute markdown link URLs; found relative: ${relativeLlmsUrls.join(', ')}`)
  }

  return pass('robots.txt, sitemap.xml, llms.txt, favicon.svg all present; sitemap and llms.txt links are absolute')
}
