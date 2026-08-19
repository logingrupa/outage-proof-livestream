import { readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { SITE_ROOT, pass, fail } from './_shared.mjs'

export const name = 'reducedMotionRespected'
const SRC_DIR = path.join(SITE_ROOT, 'src')
const SEARCH_TERM = 'prefers-reduced-motion'

function walk(directory) {
  const results = []
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const fullPath = path.join(directory, entry.name)
    if (entry.isDirectory()) {
      results.push(...walk(fullPath))
      continue
    }
    results.push(fullPath)
  }
  return results
}

export function run() {
  let stat
  try {
    stat = statSync(SRC_DIR)
  } catch {
    return fail(`${SRC_DIR} does not exist`)
  }
  if (!stat.isDirectory()) {
    return fail(`${SRC_DIR} is not a directory`)
  }

  const found = walk(SRC_DIR).some((filePath) => readFileSync(filePath, 'utf8').includes(SEARCH_TERM))
  if (!found) {
    return fail(`"${SEARCH_TERM}" not found anywhere under src/`)
  }
  return pass(`"${SEARCH_TERM}" is respected somewhere under src/`)
}
