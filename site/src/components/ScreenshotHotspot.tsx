import { useState } from 'react'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import type { DashboardHotspot } from '@/copy/types'

interface ScreenshotHotspotProps {
  hotspot: DashboardHotspot
}

// X5Q-09v: a percentage-positioned real <button>, an accent dot that pulses
// under motion-safe, and a Radix tooltip panel. The tooltip is CONTROLLED
// (open/onOpenChange) rather than left to Radix's default hover/focus-only
// behaviour, because an uncontrolled Radix tooltip never opens on touch --
// the onClick toggle below is what makes tap work, on top of Radix's own
// hover/focus open-state changes still flowing through onOpenChange.
export default function ScreenshotHotspot({ hotspot }: ScreenshotHotspotProps) {
  const [open, setOpen] = useState(false)

  return (
    <Tooltip open={open} onOpenChange={setOpen}>
      <TooltipTrigger asChild>
        <button
          type="button"
          aria-label={hotspot.label}
          onClick={() => setOpen((current) => !current)}
          className="group absolute -translate-x-1/2 -translate-y-1/2 rounded-full p-2 outline-none focus-visible:ring-2 focus-visible:ring-ring"
          style={{ left: `${hotspot.xPercent}%`, top: `${hotspot.yPercent}%` }}
        >
          <span className="motion-safe:animate-pulse block size-2.5 rounded-full bg-primary shadow-[0_0_0_4px_rgba(0,0,0,0.4)] transition-transform group-hover:scale-125 group-focus-visible:scale-125" />
        </button>
      </TooltipTrigger>
      <TooltipContent>
        <div className="flex max-w-56 flex-col gap-0.5">
          <p className="font-medium">{hotspot.title}</p>
          <p className="text-xs opacity-90">{hotspot.sentence}</p>
        </div>
      </TooltipContent>
    </Tooltip>
  )
}
