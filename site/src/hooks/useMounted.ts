import { useEffect, useState } from 'react'

// Returns false on the prerendered first paint and true after mount -- lets
// components avoid rendering theme-dependent MARKUP during prerender (the
// prerendered output and the first client render must agree).
export function useMounted() {
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])
  return mounted
}
