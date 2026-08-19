interface BrandMarkProps {
  size?: number
  className?: string
}

// Original mark (X5Q-03, no stock glyph): a continuous horizontal line
// interrupted by a gap that is visibly bridged by an arc -- the outage
// happens, and the signal still gets across. Few strokes, generous stroke
// weight relative to the viewBox, no detail that dissolves below 24px.
// `currentColor` inherits the theme -- never a baked hex.
export default function BrandMark({ size = 20, className }: BrandMarkProps) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 32 32"
      width={size}
      height={size}
      role="img"
      aria-label="A continuous line, bridged over a gap"
      className={className}
    >
      <path d="M4 16 H12" fill="none" stroke="currentColor" strokeWidth="3.2" strokeLinecap="round" />
      <path d="M20 16 H28" fill="none" stroke="currentColor" strokeWidth="3.2" strokeLinecap="round" />
      <path d="M12 16 Q16 5 20 16" fill="none" stroke="currentColor" strokeWidth="3.2" strokeLinecap="round" />
    </svg>
  )
}
