import SectionShell from '@/components/SectionShell'
import { siteCopy } from '@/copy'

function splitLeadingZero(counter: string) {
  const spaceIndex = counter.indexOf(' ')
  return { digit: counter.slice(0, spaceIndex), rest: counter.slice(spaceIndex + 1) }
}

// A typographic device, not a card grid (D-17): a full-bleed band (the
// border-y here spans the whole section, outside SectionShell's centered
// container) with each counter's leading "0" large in the accent.
export default function ZeroCounterStrip() {
  const { zeroCounters } = siteCopy

  return (
    <SectionShell
      id="zero-counters"
      heading={zeroCounters.heading}
      className="border-y border-border bg-muted/30 py-16 sm:py-20"
    >
      <dl className="grid grid-cols-1 gap-8 sm:grid-cols-2 lg:grid-cols-4">
        {zeroCounters.counters.map((counter) => {
          const { digit, rest } = splitLeadingZero(counter)
          return (
            <div key={counter}>
              <dt className="sr-only">{rest}</dt>
              <dd>
                <span className="text-5xl font-semibold tracking-tight text-primary">{digit}</span>{' '}
                <span className="text-lg text-muted-foreground">{rest}</span>
              </dd>
            </div>
          )
        })}
      </dl>
    </SectionShell>
  )
}
