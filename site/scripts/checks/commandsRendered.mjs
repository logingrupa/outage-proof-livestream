import { readDistHtml, decodeAndNormalize, pass, fail } from './_shared.mjs'
import { quickstart } from '../../src/copy/en/quickstart.ts'

export const name = 'commandsRendered'
const CODE_BLOCK_PATTERN = /<code[^>]*>([\s\S]*?)<\/code>/g

function extractCodeBlockTexts(html) {
  return [...html.matchAll(CODE_BLOCK_PATTERN)].map((match) => decodeAndNormalize(match[1]))
}

function allCommands() {
  return quickstart.groups.flatMap((group) =>
    group.steps.filter((step) => step.command).map((step) => step.command),
  )
}

export function run() {
  const codeBlockTexts = extractCodeBlockTexts(readDistHtml())
  const commands = allCommands()
  const missing = commands.filter((command) => {
    const normalizedCommand = decodeAndNormalize(command)
    return !codeBlockTexts.some((text) => text.includes(normalizedCommand))
  })

  if (missing.length > 0) {
    return fail(`commands not found inside a <code> element: ${missing.join(' | ')}`)
  }
  return pass(`all ${commands.length} quickstart commands render inside <code> elements`)
}
