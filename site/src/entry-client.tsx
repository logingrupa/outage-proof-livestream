import { StrictMode } from 'react'
import { createRoot, hydrateRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'

// The build pipeline prerenders the tree into #root, so production hydrates.
// The Vite dev server serves an empty #root and never prerenders -- hydrating
// an empty container against a full tree is a guaranteed mismatch, so dev
// mounts a fresh root instead. Branch on what is actually in the DOM rather
// than on import.meta.env.DEV, so `vite preview` and any other prerendered
// serve path take the hydrate branch too.
const container = document.getElementById('root')!

const application = (
  <StrictMode>
    <App />
  </StrictMode>
)

if (container.hasChildNodes()) {
  hydrateRoot(container, application)
} else {
  createRoot(container).render(application)
}
