import SectionShell from '@/components/SectionShell'
import RevealOnScroll from '@/components/RevealOnScroll'
import CommandBlock from '@/components/CommandBlock'
import { siteCopy } from '@/copy'

// The conversion moment (D-01) -- prose reads as reassurance, not docs.
export default function QuickstartSection() {
  const { quickstart } = siteCopy

  return (
    <SectionShell id="quickstart" heading={quickstart.heading} lead={quickstart.lead}>
      <RevealOnScroll className="grid grid-cols-1 gap-12 lg:grid-cols-2">
        {quickstart.groups.map((group) => (
          <div key={group.id}>
            <h3 className="text-lg font-semibold">{group.title}</h3>
            <ol className="mt-4 flex flex-col gap-5">
              {group.steps.map((step, index) => (
                <li key={step.prose} className="flex gap-3">
                  <span className="mt-0.5 text-sm font-medium text-muted-foreground">{index + 1}.</span>
                  <div className="flex min-w-0 flex-1 flex-col gap-2">
                    <p className="text-sm leading-relaxed text-muted-foreground">{step.prose}</p>
                    {step.command && <CommandBlock command={step.command} />}
                  </div>
                </li>
              ))}
            </ol>
          </div>
        ))}
      </RevealOnScroll>
    </SectionShell>
  )
}
