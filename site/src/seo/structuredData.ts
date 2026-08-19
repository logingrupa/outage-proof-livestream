import type { SiteCopy } from '@/copy/types'

// Pure, build-time only. `faq.mainEntity` maps the SAME `copy.faq.items`
// array the accordion renders (Task 4), so the two cannot drift.
export function buildStructuredData(copy: SiteCopy): Record<string, unknown>[] {
  const softwareApplication = {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    name: 'Outage-Proof Livestream',
    description: copy.meta.description,
    applicationCategory: 'MultimediaApplication',
    operatingSystem: 'Windows 10',
    license: 'https://www.gnu.org/licenses/agpl-3.0.html',
    codeRepository: copy.footer.repositoryHref,
    offers: {
      '@type': 'Offer',
      price: '0',
      priceCurrency: 'USD',
    },
    isAccessibleForFree: true,
  }

  const faqPage = {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: copy.faq.items.map((item) => ({
      '@type': 'Question',
      name: item.question,
      acceptedAnswer: {
        '@type': 'Answer',
        text: item.answer,
      },
    })),
  }

  return [softwareApplication, faqPage]
}
