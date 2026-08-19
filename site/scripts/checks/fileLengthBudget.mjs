import { readFileSync, readdirSync, statSync } from 'node:fs'
import path from 'node:path'
import { SITE_ROOT, pass, fail } from './_shared.mjs'

export const name = 'fileLengthBudget'

const MAX_LINES = 150
const WATCHED_DIRECTORIES = ['src', 'scripts']
// This is a budget on HAND-WRITTEN CODE. Binary assets (screenshots live in
// src/assets/ so the bundler can hash them) have no meaningful line count --
// counting newline bytes inside a PNG measures nothing.
const SOURCE_EXTENSIONS = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.css', '.html', '.json'])
// Vendored shadcn registry code, not hand-written -- excluded from the
// hand-written-code budget (documented here, not just in the plan).
const EXCLUDED_PREFIXES = [path.join(SITE_ROOT, 'src', 'components', 'ui') + path.sep]

function listFilesRecursive(directory) {
  const entries = readdirSync(directory, { withFileTypes: true })
  const files = []
  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name)
    if (entry.isDirectory()) {
      files.push(...listFilesRecursive(fullPath))
      continue
    }
    files.push(fullPath)
  }
  return files
}

function isExcluded(filePath) {
  if (!SOURCE_EXTENSIONS.has(path.extname(filePath).toLowerCase())) return true
  return EXCLUDED_PREFIXES.some((prefix) => filePath.startsWith(prefix))
}

function countLines(filePath) {
  const content = readFileSync(filePath, 'utf8')
  return content.split('\n').length
}

export function run() {
  const violations = []
  for (const relativeDirectory of WATCHED_DIRECTORIES) {
    const directory = path.join(SITE_ROOT, relativeDirectory)
    let stat
    try {
      stat = statSync(directory)
    } catch {
      continue
    }
    if (!stat.isDirectory()) continue

    for (const filePath of listFilesRecursive(directory)) {
      if (isExcluded(filePath)) continue
      const lineCount = countLines(filePath)
      if (lineCount > MAX_LINES) {
        violations.push(`${path.relative(SITE_ROOT, filePath)} (${lineCount} lines)`)
      }
    }
  }

  if (violations.length > 0) {
    return fail(`files exceeding the ${MAX_LINES}-line budget: ${violations.join(', ')}`)
  }
  return pass(`no file under src/ or scripts/ (excluding components/ui/) exceeds ${MAX_LINES} lines`)
}
