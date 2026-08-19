import type { CallToAction } from './types'

// Split out of types.ts to keep that file under its 150-line budget -- same
// convention as dashboardTypes.ts.
export interface ClosingCallToActionCopy {
  heading: string
  lines: string[]
  // Deliberately NOT the hero's primary label -- that string may occur exactly
  // once on the page (D-01).
  callToAction: CallToAction
  microcopy: string
}
