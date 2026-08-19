import SectionShell from '@/components/SectionShell'
import { siteCopy } from '@/copy'

const MATTHEW_QUOTE = '"Freely you have received; freely give."'
const MATTHEW_ATTRIBUTION = '-- Matthew 10:8'
const MATTHEW_LEAD_IN = 'It is free, and it stays free.'

// The Matthew 10:8 line (D-04, locked order index 2) renders as a lead-in
// sentence plus a real <blockquote>/<cite> pair, so the quote gets correct
// semantics without breaking the verbatim check -- lockedCopyVerbatim
// strips tags before comparing, so this sibling-element split still reads
// as one contiguous locked string in document order.
export default function MissionSection() {
  const { mission } = siteCopy

  return (
    <SectionShell id="mission" heading={mission.heading} className="bg-muted/20">
      <div className="flex max-w-2xl flex-col gap-8 text-lg leading-relaxed text-muted-foreground">
        {mission.lines.map((line) =>
          line.includes(MATTHEW_QUOTE) ? (
            <div key="matthew" className="flex flex-col gap-4">
              <p>{MATTHEW_LEAD_IN}</p>
              <blockquote className="border-l-2 border-border pl-4 italic">
                <p>{MATTHEW_QUOTE}</p>
                <cite className="mt-1 block text-sm not-italic">{MATTHEW_ATTRIBUTION}</cite>
              </blockquote>
            </div>
          ) : (
            <p key={line}>{line}</p>
          ),
        )}
      </div>
    </SectionShell>
  )
}
