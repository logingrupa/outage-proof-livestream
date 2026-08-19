import { useCallback, useEffect, useRef, useState } from 'react'

const RESET_DELAY_MS = 2000

export function useCopyToClipboard() {
  const [copied, setCopied] = useState(false)
  const resetTimer = useRef<ReturnType<typeof setTimeout>>(undefined)

  useEffect(() => () => clearTimeout(resetTimer.current), [])

  const copy = useCallback(async (text: string) => {
    if (typeof navigator === 'undefined' || !navigator.clipboard) return
    try {
      await navigator.clipboard.writeText(text)
    } catch {
      return
    }
    setCopied(true)
    clearTimeout(resetTimer.current)
    resetTimer.current = setTimeout(() => setCopied(false), RESET_DELAY_MS)
  }, [])

  return { copied, copy }
}
