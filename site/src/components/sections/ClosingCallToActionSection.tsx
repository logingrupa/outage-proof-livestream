import { Button } from '@/components/ui/button'
import { siteCopy } from '@/copy'

// The closing conversion moment, after the mission. Its button is a quieter
// outline variant and carries its own label -- the hero keeps the single loud
// CTA on the page (D-01).
export default function ClosingCallToActionSection() {
  const { closingCallToAction } = siteCopy

  return (
    <section
      id="closing"
      aria-labelledby="closing-heading"
      className="border-y border-border bg-muted/20 py-24 sm:py-28"
    >
      <div className="mx-auto flex max-w-3xl flex-col items-start gap-6 px-6">
        <h2 id="closing-heading" className="text-3xl font-semibold tracking-tight text-balance sm:text-4xl">
          {closingCallToAction.heading}
        </h2>
        {closingCallToAction.lines.map((line) => (
          <p key={line} className="text-lg leading-relaxed text-muted-foreground">
            {line}
          </p>
        ))}
        <div className="flex flex-col gap-3">
          <Button asChild size="lg" variant="outline" className="h-12 px-8 text-base font-semibold">
            <a href={closingCallToAction.callToAction.href}>{closingCallToAction.callToAction.label}</a>
          </Button>
          <p className="text-sm text-muted-foreground">{closingCallToAction.microcopy}</p>
        </div>
      </div>
    </section>
  )
}
