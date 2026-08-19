import { serviceFigures } from '@/data/serviceFigures'
import type { DashboardFiguresCopy } from '@/copy/types'

interface ServiceFiguresPanelProps {
  figures: DashboardFiguresCopy
}

// Labels come from copy, values come from src/data/serviceFigures.ts. Nothing
// is computed here -- if a number is wrong, it is wrong in exactly one place.
export default function ServiceFiguresPanel({ figures }: ServiceFiguresPanelProps) {
  return (
    <section aria-labelledby="service-figures-heading" className="flex flex-col gap-6">
      <div className="flex flex-col gap-2">
        <h3 id="service-figures-heading" className="text-xl font-semibold tracking-tight">
          {figures.heading}
        </h3>
        <p className="max-w-2xl text-muted-foreground">{figures.lead}</p>
      </div>
      <dl className="grid grid-cols-1 gap-px overflow-hidden rounded-xl border border-border bg-border sm:grid-cols-2 lg:grid-cols-3">
        {figures.items.map((item) => (
          <div key={item.id} className="flex flex-col gap-1 bg-card/60 p-5">
            <dt className="text-sm text-muted-foreground">{item.label}</dt>
            <dd className="font-mono text-3xl font-semibold tracking-tight tabular-nums">
              {serviceFigures[item.id]}
            </dd>
            <p className="text-sm text-muted-foreground">{item.detail}</p>
          </div>
        ))}
      </dl>
    </section>
  )
}
