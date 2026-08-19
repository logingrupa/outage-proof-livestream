import type { ReactNode } from 'react'
import { usePointerTilt } from '@/hooks/usePointerTilt'

interface ScreenshotFrameProps {
  children: ReactNode
}

// X5Q-09: the perspective wrapper, resting tilt, hover straighten, and
// shadow -- one component, one responsibility. Every transform and every
// transition lives behind Tailwind's `motion-safe` variant, so
// `prefers-reduced-motion` yields a flat, still, untilted frame -- not a
// slower tilt, no tilt at all (this covers the RESTING tilt too, not just
// the hover transition). usePointerTilt (D-25) upgrades this to a live
// cursor-follow on desktop, inline `style` overriding the same `transform`
// property -- it returns null (no override) on touch or reduced motion, so
// the CSS classes below are always the correct fallback.
//
// D-24: the frame surface stays a fixed dark neutral in BOTH site themes --
// it is presenting a screen, and the captured dashboard is dark-only, so
// this deliberately does not use theme tokens (bg-background would flip
// white in the light theme).
export default function ScreenshotFrame({ children }: ScreenshotFrameProps) {
  const { elementRef, transform } = usePointerTilt<HTMLDivElement>()

  return (
    <div className="[perspective:1600px]">
      <div
        ref={elementRef}
        style={transform ? { transform } : undefined}
        className="motion-safe:[transform:rotateX(6deg)_rotateY(-8deg)] motion-safe:hover:[transform:rotateX(0deg)_rotateY(0deg)_scale(1.02)] motion-safe:will-change-transform motion-safe:transition-[transform,box-shadow] motion-safe:duration-500 motion-safe:ease-out overflow-hidden rounded-xl border border-white/10 bg-neutral-950 shadow-xl shadow-black/40 hover:shadow-2xl hover:shadow-black/60"
      >
        {children}
      </div>
    </div>
  )
}
