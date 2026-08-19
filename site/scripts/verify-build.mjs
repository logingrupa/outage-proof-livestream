#!/usr/bin/env node
// Thin composer: discovers every check module under scripts/checks/ (any
// file not starting with `_`, which marks shared/non-check helpers), runs
// each one's named `run` export, prints one PASS/FAIL line per check, and
// exits 1 listing every failure. Later tasks add check modules here without
// editing this file or any existing check (SRP).
import { readdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const SCRIPTS_DIR = path.dirname(fileURLToPath(import.meta.url))
const CHECKS_DIR = path.join(SCRIPTS_DIR, 'checks')

function discoverCheckFiles() {
  return readdirSync(CHECKS_DIR)
    .filter((fileName) => fileName.endsWith('.mjs') && !fileName.startsWith('_'))
    .sort()
}

async function runAllChecks() {
  const checkFiles = discoverCheckFiles()
  const failures = []

  for (const fileName of checkFiles) {
    const modulePath = pathToFileURL(path.join(CHECKS_DIR, fileName)).href
    const checkModule = await import(modulePath)
    const checkName = checkModule.name ?? fileName

    let result
    try {
      result = await checkModule.run()
    } catch (error) {
      result = { pass: false, message: error instanceof Error ? error.message : String(error) }
    }

    const status = result.pass ? 'PASS' : 'FAIL'
    console.log(`${status} ${checkName}: ${result.message}`)
    if (!result.pass) {
      failures.push(`${checkName}: ${result.message}`)
    }
  }

  if (failures.length > 0) {
    console.error(`\n${failures.length} check(s) failed:`)
    for (const failure of failures) {
      console.error(`  - ${failure}`)
    }
    process.exit(1)
  }
}

await runAllChecks()
