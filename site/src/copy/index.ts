import type { SiteCopy, SupportedLocale } from './types'
import { en } from './en'

export const DEFAULT_LOCALE: SupportedLocale = 'en'

const copyByLocale: Record<SupportedLocale, SiteCopy> = {
  en,
}

// A second locale is a data change here, not a refactor: add its key to
// SupportedLocale, add its directory under src/copy/, and register it above.
export function getCopy(locale: SupportedLocale): SiteCopy {
  return copyByLocale[locale]
}

export const siteCopy: SiteCopy = getCopy(DEFAULT_LOCALE)
