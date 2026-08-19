// Helper (leading underscore -- skipped by verify-build.mjs's discovery).
// Low-level Chrome DevTools Protocol transport: resolve a browser binary,
// wait for its DevToolsActivePort file, connect a WebSocket to the page
// target, and provide a thin request/response-by-id plus event fan-out.
// Node 24 built-in fetch + WebSocket only -- no Puppeteer, no Playwright (D-27).
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'

const CHROME_CANDIDATES = [
  process.env.CHROME_PATH,
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
].filter(Boolean)

export function resolveBrowserBinary() {
  for (const candidate of CHROME_CANDIDATES) {
    if (existsSync(candidate)) return candidate
  }
  throw new Error(`no headless-capable browser found. Checked: ${CHROME_CANDIDATES.join(', ')}`)
}

export function waitForDevToolsActivePort(userDataDir, timeoutMs = 15000) {
  const filePath = path.join(userDataDir, 'DevToolsActivePort')
  const start = Date.now()
  return new Promise((resolve, reject) => {
    const poll = () => {
      if (existsSync(filePath)) {
        resolve(Number(readFileSync(filePath, 'utf8').split('\n')[0]))
        return
      }
      if (Date.now() - start > timeoutMs) {
        reject(new Error(`DevToolsActivePort did not appear within ${timeoutMs}ms`))
        return
      }
      setTimeout(poll, 100)
    }
    poll()
  })
}

export async function connectToPageTarget(port) {
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
  const page = targets.find((target) => target.type === 'page')
  if (!page) throw new Error('no page target found in /json/list')
  const socket = new WebSocket(page.webSocketDebuggerUrl)
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', () => resolve(), { once: true })
    socket.addEventListener('error', (event) => reject(new Error(`CDP websocket error: ${event.message ?? event}`)), { once: true })
  })
  return socket
}

// Thin request/response-by-id plus event fan-out over one raw CDP socket.
export function createRpc(socket) {
  let nextId = 1
  const pending = new Map()
  const eventHandlers = new Map()

  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data)
    if (message.id !== undefined && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id)
      pending.delete(message.id)
      if (message.error) reject(new Error(message.error.message))
      else resolve(message.result)
      return
    }
    if (message.method) {
      for (const handler of eventHandlers.get(message.method) ?? []) handler(message.params)
    }
  })

  function send(method, params = {}) {
    const id = nextId++
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject })
      socket.send(JSON.stringify({ id, method, params }))
    })
  }

  function onEvent(method, handler) {
    const handlers = eventHandlers.get(method) ?? []
    handlers.push(handler)
    eventHandlers.set(method, handlers)
  }

  return { send, onEvent }
}
