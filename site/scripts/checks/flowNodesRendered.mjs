import { readDistHtml, decodeAndNormalize, pass, fail } from './_shared.mjs'
import { howItWorks } from '../../src/copy/en/howItWorks.ts'

export const name = 'flowNodesRendered'

export function run() {
  const html = decodeAndNormalize(readDistHtml())
  const missing = howItWorks.flowNodes
    .map((node) => decodeAndNormalize(node.label))
    .filter((label) => !html.includes(label))

  if (missing.length > 0) {
    return fail(`architecture-flow node label(s) not found: ${missing.join(', ')}`)
  }
  return pass(`all ${howItWorks.flowNodes.length} architecture-flow node labels present as text`)
}
