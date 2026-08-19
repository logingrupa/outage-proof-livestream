import { startStaticServer } from './_staticServer.mjs'
import { withHeadlessSession } from './_headlessSession.mjs'
import { pass, fail } from './_shared.mjs'
import { quickstart } from '../../src/copy/en/quickstart.ts'

export const name = 'clipboardPayloadUnchanged'

// Stubs navigator.clipboard before ANY page script runs (D-23) -- installed
// via Page.addScriptToEvaluateOnNewDocument, so it exists before hydration
// wires the real click handlers.
const CLIPBOARD_STUB_SCRIPT = `(() => {
  window.__gsdClipboardCalls = [];
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: { writeText: (text) => { window.__gsdClipboardCalls.push(text); return Promise.resolve(); } },
  });
})();`

// Clicks every copy button in document order and returns the captured
// payload array. A brief settle delay covers React's event-batching, not
// network latency -- the stub resolves synchronously.
const CLICK_ALL_COPY_BUTTONS_SCRIPT = `(async () => {
  const buttons = Array.from(document.querySelectorAll('button[aria-label^="Copy "]'));
  for (const button of buttons) button.click();
  await new Promise((resolve) => setTimeout(resolve, 200));
  return window.__gsdClipboardCalls || [];
})()`

function expectedCommands() {
  return quickstart.groups.flatMap((group) => group.steps.map((step) => step.command).filter((command) => command !== undefined))
}

function multisetsEqual(actual, expected) {
  if (actual.length !== expected.length) return false
  const sortedActual = [...actual].sort()
  const sortedExpected = [...expected].sort()
  return sortedActual.every((value, index) => value === sortedExpected[index])
}

// Real browser, real clicks, real captured payloads -- proves wrapping never
// touches the clipboard string, which is a claim source inspection cannot
// make (D-23).
export async function run() {
  const server = await startStaticServer()
  try {
    return await withHeadlessSession(
      server.baseUrl,
      async (session) => {
        const captured = await session.evaluate(CLICK_ALL_COPY_BUTTONS_SCRIPT)
        const expected = expectedCommands()

        if (captured.length === 0) {
          return fail('captured clipboard payload array is empty -- the copy buttons never wired up (a different bug)')
        }
        if (!multisetsEqual(captured, expected)) {
          return fail(
            `captured payloads do not match src/copy/en/quickstart.ts commands. captured=${JSON.stringify(captured)} expected=${JSON.stringify(expected)}`,
          )
        }
        return pass(`all ${captured.length} copied payload(s) are byte-identical to the quickstart command dictionary`)
      },
      { initScripts: [CLIPBOARD_STUB_SCRIPT] },
    )
  } finally {
    await server.close()
  }
}
