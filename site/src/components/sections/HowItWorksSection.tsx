import SectionShell from '@/components/SectionShell'
import RevealOnScroll from '@/components/RevealOnScroll'
import ArchitectureFlow from '@/components/ArchitectureFlow'
import { siteCopy } from '@/copy'

export default function HowItWorksSection() {
  const { howItWorks } = siteCopy

  return (
    <SectionShell id="how-it-works" heading={howItWorks.heading} lead={howItWorks.lead}>
      <RevealOnScroll className="flex flex-col gap-6">
        <div className="flex max-w-2xl flex-col gap-4">
          {howItWorks.paragraphs.map((paragraph) => (
            <p key={paragraph} className="text-lg leading-relaxed text-muted-foreground">
              {paragraph}
            </p>
          ))}
        </div>
        <ArchitectureFlow />
      </RevealOnScroll>
    </SectionShell>
  )
}
