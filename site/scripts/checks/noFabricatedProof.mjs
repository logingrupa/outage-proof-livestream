import { readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { SITE_ROOT, pass, fail } from './_shared.mjs'

export const name = 'noFabricatedProof'
const COPY_DIR = path.join(SITE_ROOT, 'src', 'copy')

// D-05: one production deployment exists; anything beyond that is
// unverifiable. These patterns cover the fabrication shapes the truthfulness
// gate must catch -- deliberately over-inclusive, since a false positive
// here just means rewording a sentence, and a false negative ships a lie.
const FORBIDDEN_PATTERNS = [
  { label: 'fabricated scale/headcount claim', pattern: /\b\d[\d,]*\+?\s*(churches?|congregations?|users?|installs?|installations?|downloads?|customers?)\b/i },
  { label: 'fabricated uptime/availability percentage', pattern: /\b\d{1,3}(\.\d+)?\s*%\s*(uptime|availability)\b/i },
  { label: 'fabricated latency/throughput benchmark', pattern: /\b\d+(\.\d+)?\s*(ms|mbps|gbps|kbps)\b/i },
  { label: 'testimonial-shaped quotation with attribution', pattern: /"[^"]{15,}"\s*[-–—]\s*[A-Z][a-zA-Z.]+\s+[A-Z]/ },
  { label: 'unverifiable praise/authority claim', pattern: /\b(rated|awarded?|award-winning|trusted by)\b/i },
]

function listFilesRecursive(directory) {
  const files = []
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const fullPath = path.join(directory, entry.name)
    if (entry.isDirectory()) {
      files.push(...listFilesRecursive(fullPath))
      continue
    }
    files.push(fullPath)
  }
  return files
}

export function run() {
  let stat
  try {
    stat = statSync(COPY_DIR)
  } catch {
    return fail(`${COPY_DIR} does not exist`)
  }
  if (!stat.isDirectory()) {
    return fail(`${COPY_DIR} is not a directory`)
  }

  const offenders = []
  for (const filePath of listFilesRecursive(COPY_DIR)) {
    const content = readFileSync(filePath, 'utf8')
    for (const { label, pattern } of FORBIDDEN_PATTERNS) {
      const match = content.match(pattern)
      if (match) {
        offenders.push(`${path.relative(SITE_ROOT, filePath)}: ${label} ("${match[0]}")`)
      }
    }
  }

  if (offenders.length > 0) {
    return fail(`fabricated-proof pattern(s) found: ${offenders.join(' | ')}`)
  }
  return pass('src/copy/** is clean of fabricated proof patterns')
}
