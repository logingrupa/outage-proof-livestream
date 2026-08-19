import { useLayoutEffect, useRef, useState, type ReactNode } from 'react'

interface RevealOnScrollProps {
  children: ReactNode
  className?: string
}

// Static markup (prerendered AND the first client render) always renders
// children fully visible -- no hiding class ships in server output; the
// check that enforces this only inspects the built dist/index.html. Only
// after mount does this add a pending/animate-in class, and only when the
// visitor has not asked for reduced motion (early return, no observer at
// all otherwise -- children stay untouched).
export default function RevealOnScroll({ children, className = '' }: RevealOnScrollProps) {
  const elementRef = useRef<HTMLDivElement>(null)
  const [motionClass, setMotionClass] = useState('')

  useLayoutEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const element = elementRef.current
    if (!element) return

    setMotionClass('reveal-pending')
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry.isIntersecting) return
        setMotionClass('reveal-in')
        observer.disconnect()
      },
      { threshold: 0.15 },
    )
    observer.observe(element)
    return () => observer.disconnect()
  }, [])

  return (
    <div ref={elementRef} className={`${className} ${motionClass}`.trim()}>
      {children}
    </div>
  )
}
