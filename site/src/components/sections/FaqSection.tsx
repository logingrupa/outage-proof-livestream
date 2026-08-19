import SectionShell from '@/components/SectionShell'
import { Accordion, AccordionItem, AccordionTrigger, AccordionContent } from '@/components/ui/accordion'
import { siteCopy } from '@/copy'

// Radix Accordion, not a hand-rolled disclosure widget. `AccordionPrimitive.Header`
// (wrapped by AccordionTrigger) renders an <h3> by default -- the correct
// heading level under this section's <h2>, and exactly what the
// faqStructuredDataMatchesVisible check reads. `forceMount` keeps every
// answer in the prerendered HTML (D-08: prerendered content is priority
// one), CSS still collapses it visually via the Radix data-state height var.
export default function FaqSection() {
  const { faq } = siteCopy

  return (
    <SectionShell id="faq" heading={faq.heading} lead={faq.lead}>
      <Accordion type="single" collapsible className="max-w-2xl">
        {faq.items.map((item) => (
          <AccordionItem key={item.question} value={item.question}>
            <AccordionTrigger>{item.question}</AccordionTrigger>
            <AccordionContent forceMount>
              <p className="text-muted-foreground">{item.answer}</p>
            </AccordionContent>
          </AccordionItem>
        ))}
      </Accordion>
    </SectionShell>
  )
}
