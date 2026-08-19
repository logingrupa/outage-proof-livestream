import { Circle, Moon, Sun } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { useTheme } from '@/hooks/useTheme'
import { useMounted } from '@/hooks/useMounted'
import { siteCopy } from '@/copy'

// Critical prerender rule: until mounted, render a fixed-size neutral
// placeholder -- never a sun-or-moon decided by theme, and no tooltip --
// so the prerendered markup and the first client render agree and nothing
// shifts layout (X5Q-05 keeps this contract; only the mounted, interactive
// button gets wrapped).
export default function ThemeToggle() {
  const mounted = useMounted()
  const { theme, toggleTheme } = useTheme()
  const { themeToggle } = siteCopy

  if (!mounted) {
    return (
      <Button variant="ghost" size="icon" aria-hidden="true" tabIndex={-1} disabled>
        <Circle className="size-4" />
      </Button>
    )
  }

  const isDark = theme === 'dark'
  // The aria-label stays literal and descriptive; the tooltip is the
  // playful surface. The two must never contradict each other for a
  // screen-reader user -- both describe the SAME upcoming action.
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          onClick={toggleTheme}
          aria-label={isDark ? 'Switch to light theme' : 'Switch to dark theme'}
        >
          {isDark ? <Sun className="size-4" /> : <Moon className="size-4" />}
        </Button>
      </TooltipTrigger>
      <TooltipContent>{isDark ? themeToggle.tooltipToLight : themeToggle.tooltipToDark}</TooltipContent>
    </Tooltip>
  )
}
