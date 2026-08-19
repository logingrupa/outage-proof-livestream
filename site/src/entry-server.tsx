// SSR/prerender entry. Deliberately imports NO CSS -- Vite's server build has
// no browser environment, and nothing reachable from this module may touch
// `window`, `document`, or `location` at module scope (the classic prerender
// crash).
import { prerenderToNodeStream } from 'react-dom/static'
import App from './App.tsx'
import { siteCopy } from '@/copy'
import { renderStructuredDataScriptTags } from '@/seo/structuredDataScriptTags'

export async function renderPageToStream() {
  const { prelude } = await prerenderToNodeStream(<App />)
  return prelude
}

// D-20: JSON-LD is emitted here, through the SERVER build, so the `@/` alias
// stays resolved and `src/copy/en/faq.ts` remains the single source feeding
// both the accordion and the JSON-LD -- prerender.mjs never re-resolves the
// copy tree by hand.
export function renderStructuredDataScriptTagsForHead() {
  return renderStructuredDataScriptTags(siteCopy)
}
