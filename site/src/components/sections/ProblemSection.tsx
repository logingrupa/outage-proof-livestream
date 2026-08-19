import SectionShell from '@/components/SectionShell'
import RevealOnScroll from '@/components/RevealOnScroll'
import { siteCopy } from '@/copy'

export default function ProblemSection() {
  const { problem } = siteCopy

  return (
    <SectionShell id="problem" heading={problem.heading} lead={problem.lead}>
      <RevealOnScroll className="flex max-w-2xl flex-col gap-6">
        {problem.paragraphs.map((paragraph) => (
          <p key={paragraph} className="text-lg leading-relaxed text-muted-foreground">
            {paragraph}
          </p>
        ))}
      </RevealOnScroll>
    </SectionShell>
  )
}
