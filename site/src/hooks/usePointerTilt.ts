import { useEffect, useRef, useState } from 'react'

const MAX_TILT_DEGREES = 10

function prefersReducedMotion() {
  return typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

function hasCoarsePointer() {
  return typeof window !== 'undefined' && window.matchMedia('(pointer: coarse)').matches
}

// D-25 desktop upgrade: live cursor-follow tilt instead of the fixed hover
// transform. Hard early return (no listeners ever attached, `transform`
// stays null forever) when reduced motion is requested or the pointer is
// coarse -- in both cases the caller's CSS motion-safe resting/hover tilt
// is the fallback, with no error and no visible control left stranded.
// The mobile DeviceOrientationEvent half of D-25 is deliberately NOT
// implemented here: iOS 13+ requires requestPermission() from an explicit
// user tap, never on load, and wiring a real opt-in control for it would
// stop this being one small single-responsibility hook. Skipped per the
// user's explicit pre-authorisation ("if no skip").
export function usePointerTilt<T extends HTMLElement>() {
  const elementRef = useRef<T>(null)
  const [transform, setTransform] = useState<string | null>(null)

  useEffect(() => {
    if (prefersReducedMotion() || hasCoarsePointer()) return undefined
    const current = elementRef.current
    if (!current) return undefined
    // Narrowed to a non-null local binding: TypeScript's control-flow
    // analysis does not carry the `if (!current)` guard above into the
    // nested function declarations below, even though `current` is const.
    const element: T = current

    function handlePointerMove(event: PointerEvent) {
      const bounds = element.getBoundingClientRect()
      const relativeX = (event.clientX - bounds.left) / bounds.width - 0.5
      const relativeY = (event.clientY - bounds.top) / bounds.height - 0.5
      const rotateY = relativeX * MAX_TILT_DEGREES * 2
      const rotateX = relativeY * -MAX_TILT_DEGREES * 2
      setTransform(`rotateX(${rotateX.toFixed(2)}deg) rotateY(${rotateY.toFixed(2)}deg) scale(1.02)`)
    }

    function handlePointerLeave() {
      setTransform(null)
    }

    element.addEventListener('pointermove', handlePointerMove)
    element.addEventListener('pointerleave', handlePointerLeave)
    return () => {
      element.removeEventListener('pointermove', handlePointerMove)
      element.removeEventListener('pointerleave', handlePointerLeave)
    }
  }, [])

  return { elementRef, transform }
}
