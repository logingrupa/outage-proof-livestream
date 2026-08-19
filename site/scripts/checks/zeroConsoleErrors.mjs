import { startStaticServer } from './_staticServer.mjs'
import { withHeadlessSession } from './_headlessSession.mjs'
import { pass, fail } from './_shared.mjs'

export const name = 'zeroConsoleErrors'

function describeConsoleMessage(entry) {
  const args = (entry.args ?? []).map((arg) => arg.value ?? arg.description ?? String(arg)).join(' ')
  return `console.${entry.type}: ${args}`
}

function describeException(entry) {
  return `uncaught exception: ${entry.exceptionDetails?.exception?.description ?? entry.exceptionDetails?.text ?? 'unknown'}`
}

function describeLogEntry(entry) {
  return `Log ${entry.level}: ${entry.text}`
}

// Loads the BUILT site in a real headless browser and fails on any
// console.error/warning, any uncaught exception, or any browser-level Log
// entry of level error/warning (which also catches a 404 for any referenced
// asset). Also asserts #root actually has child nodes, so a blank page
// cannot trivially "pass".
export async function run() {
  const server = await startStaticServer()
  try {
    return await withHeadlessSession(server.baseUrl, async (session) => {
      const rootHasChildren = await session.evaluate(
        'document.title.length > 0 && document.getElementById("root") !== null && document.getElementById("root").children.length > 0',
      )
      if (!rootHasChildren) {
        return fail('page did not navigate to real content -- document.title is empty or #root has no children')
      }

      const offenders = [
        ...session.consoleMessages
          .filter((entry) => entry.type === 'error' || entry.type === 'warning')
          .map(describeConsoleMessage),
        ...session.exceptions.map(describeException),
        ...session.logEntries
          .filter((entry) => entry.level === 'error' || entry.level === 'warning')
          .map(describeLogEntry),
      ]

      if (offenders.length > 0) {
        return fail(`captured console error(s)/warning(s): ${offenders.join(' | ')}`)
      }

      const totalMessages = session.consoleMessages.length + session.exceptions.length + session.logEntries.length
      return pass(`zero console errors/warnings/exceptions (${totalMessages} total message(s) of any level observed)`)
    })
  } finally {
    await server.close()
  }
}
