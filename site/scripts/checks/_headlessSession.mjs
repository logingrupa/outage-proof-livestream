// Helper (leading underscore -- skipped by verify-build.mjs's discovery).
// Spawns a real Chromium-family browser headlessly, attaches CDP listeners
// on about:blank BEFORE the page under test navigates (so the earliest
// console output is never lost), then hands the caller an attached session.
import { spawn } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { resolveBrowserBinary, waitForDevToolsActivePort, connectToPageTarget, createRpc } from './_cdpTransport.mjs'

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function navigateAndSettle(rpc, url, settleMs, navigateTimeoutMs) {
  const loadFired = new Promise((resolve) => rpc.onEvent('Page.loadEventFired', () => resolve()))
  await rpc.send('Page.navigate', { url })
  await Promise.race([
    loadFired,
    wait(navigateTimeoutMs).then(() => {
      throw new Error(`Page.loadEventFired did not fire within ${navigateTimeoutMs}ms`)
    }),
  ])
  await wait(settleMs)
}

// Registers the three console-truth collectors BEFORE navigation, so nothing
// logged during the earliest hydration pass is lost to a latecomer listener.
function attachConsoleCollectors(rpc) {
  const consoleMessages = []
  const exceptions = []
  const logEntries = []
  rpc.onEvent('Runtime.consoleAPICalled', (params) => consoleMessages.push(params))
  rpc.onEvent('Runtime.exceptionThrown', (params) => exceptions.push(params))
  rpc.onEvent('Log.entryAdded', (params) => logEntries.push(params.entry))
  return { consoleMessages, exceptions, logEntries }
}

function launchBrowser(browserBinary, userDataDir) {
  return spawn(
    browserBinary,
    [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      `--user-data-dir=${userDataDir}`,
      '--remote-debugging-port=0',
      'about:blank',
    ],
    { stdio: 'ignore' },
  )
}

// Public entry point. `callback(session)` runs after navigation + the settle
// window, with `session.evaluate`/`session.onEvent`/`session.send` available
// for post-load assertions or interactions (e.g. clicking copy buttons), plus
// `consoleMessages`/`exceptions`/`logEntries` captured from the moment the
// CDP domains were enabled -- BEFORE Page.navigate -- through the settle
// window, covering the whole hydration pass. `options.initScripts` run
// before ANY page script via Page.addScriptToEvaluateOnNewDocument --
// required for stubs like the clipboard shim, which must exist before
// hydration wires the real handlers.
export async function withHeadlessSession(url, callback, options = {}) {
  const { initScripts = [], settleMs = 800, navigateTimeoutMs = 15000 } = options
  const browserBinary = resolveBrowserBinary()
  const userDataDir = mkdtempSync(path.join(os.tmpdir(), 'gsd-headless-'))
  const browserProcess = launchBrowser(browserBinary, userDataDir)

  let socket
  try {
    const port = await waitForDevToolsActivePort(userDataDir)
    socket = await connectToPageTarget(port)
    const rpc = createRpc(socket)

    await rpc.send('Runtime.enable')
    await rpc.send('Log.enable')
    await rpc.send('Page.enable')
    const collected = attachConsoleCollectors(rpc)
    for (const source of initScripts) {
      await rpc.send('Page.addScriptToEvaluateOnNewDocument', { source })
    }

    const session = {
      onEvent: rpc.onEvent,
      send: rpc.send,
      ...collected,
      evaluate: async (expression) => {
        const result = await rpc.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true })
        if (result.exceptionDetails) throw new Error(`evaluate failed: ${result.exceptionDetails.text}`)
        return result.result.value
      },
    }

    await navigateAndSettle(rpc, url, settleMs, navigateTimeoutMs)
    return await callback(session)
  } finally {
    try {
      socket?.close()
    } catch {
      // already closed
    }
    await terminateBrowserProcess(browserProcess)
    // Windows keeps a file lock on the user-data-dir for a moment after the
    // process handle reports closed -- retry the removal rather than fail
    // the whole check on a teardown race unrelated to what it is proving.
    rmSync(userDataDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 })
  }
}

// Waits (bounded) for the spawned browser to actually exit before the
// caller attempts to delete its user-data-dir -- `.kill()` only requests
// termination, it does not wait for it.
function terminateBrowserProcess(browserProcess, timeoutMs = 5000) {
  if (browserProcess.exitCode !== null || browserProcess.killed) return Promise.resolve()
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, timeoutMs)
    browserProcess.once('exit', () => {
      clearTimeout(timer)
      resolve()
    })
    browserProcess.kill()
  })
}
