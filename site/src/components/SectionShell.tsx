import type { ReactNode } from 'react'

interface SectionShellProps {
  id: string
  heading: string
  lead?: string
  children: ReactNode
  className?: string
}

// The one shared layout primitive (D-17): every section gets the same
// vertical rhythm and container width, set once here and never re-tuned
// per section.
export default function SectionShell({ id, heading, lead, children, className = '' }: SectionShellProps) {
  const headingId = `${id}-heading`
  return (
    <section id={id} aria-labelledby={headingId} className={`py-24 sm:py-32 ${className}`}>
      <div className="mx-auto max-w-5xl px-6">
        <h2 id={headingId} className="text-3xl font-semibold tracking-tight sm:text-4xl">
          {heading}
        </h2>
        {lead && <p className="mt-3 max-w-2xl text-lg text-muted-foreground">{lead}</p>}
        <div className="mt-10">{children}</div>
      </div>
    </section>
  )
}
