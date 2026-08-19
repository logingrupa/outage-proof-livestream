import { useCallback, useState } from 'react'

export type Theme = 'light' | 'dark'

function resolveInitialTheme(): Theme {
  if (typeof document === 'undefined') return 'light'
  return document.documentElement.classList.contains('dark') ? 'dark' : 'light'
}

function applyTheme(theme: Theme) {
  document.documentElement.classList.toggle('dark', theme === 'dark')
  localStorage.setItem('theme', theme)
}

// No `next-themes` (D-11): the inline script in index.html owns the no-flash
// first paint, and this hook only owns the toggle after mount.
export function useTheme() {
  const [theme, setThemeState] = useState<Theme>(resolveInitialTheme)

  const setTheme = useCallback((next: Theme) => {
    applyTheme(next)
    setThemeState(next)
  }, [])

  const toggleTheme = useCallback(() => {
    setTheme(theme === 'dark' ? 'light' : 'dark')
  }, [theme, setTheme])

  return { theme, setTheme, toggleTheme }
}
