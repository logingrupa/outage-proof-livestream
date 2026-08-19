import type { DashboardCopy } from './dashboardTypes'
import type { ClosingCallToActionCopy } from './closingTypes'

export type { ClosingCallToActionCopy } from './closingTypes'

export type SupportedLocale = 'en'
export type { DashboardCopy, DashboardHotspot, DashboardShot, DashboardFigure, DashboardFiguresCopy, DashboardChartCopy } from './dashboardTypes'

export interface CallToAction {
  label: string
  href: string
}

export interface HeroCopy {
  headline: string
  subheadline: string
  primaryCallToAction: CallToAction
  // Supporting line under the CTA (X5Q-06): what happens next -- no benchmark figures, no repeat of the CTA label.
  ctaMicrocopy: string
  secondaryCallToAction: CallToAction
  // Caption under the hero screenshot -- says what the picture is, never repeats the CTA label (singleLoudCallToAction).
  screenshotCaption: string
}

export interface ProblemCopy {
  heading: string
  lead: string
  paragraphs: string[]
}

export interface FlowNode {
  id: string
  label: string
  description: string
  emphasised: boolean
}

export interface HowItWorksCopy {
  heading: string
  lead: string
  paragraphs: string[]
  flowNodes: FlowNode[]
}

export interface ZeroCountersCopy {
  heading: string
  counters: string[]
}

export interface QuickstartStep {
  prose: string
  command?: string
}

export interface QuickstartGroup {
  id: string
  title: string
  steps: QuickstartStep[]
}

export interface QuickstartCopy {
  heading: string
  lead: string
  groups: QuickstartGroup[]
}

export interface TransportRow {
  transport: string
  status: string
  notes: string
}

export interface TransportCopy {
  heading: string
  lead: string
  rows: TransportRow[]
  defaultReason: string
}

export interface RequirementsGroup {
  title: string
  items: string[]
}

export interface RequirementsCopy {
  heading: string
  groups: RequirementsGroup[]
}

export interface FaqItem {
  question: string
  answer: string
}

export interface FaqCopy {
  heading: string
  lead: string
  items: FaqItem[]
}

export interface MissionCopy {
  heading: string
  lines: string[]
}

export interface FooterCopy {
  // D-26: one licence mention -- a prefix, a single linked label, a suffix. No second occurrence anywhere in the footer.
  licencePrefix: string
  licenceLinkLabel: string
  licenceHref: string
  licenceSuffix: string
  repositoryLabel: string
  repositoryHref: string
  attribution: string
}

export interface ThemeToggleCopy {
  // Tooltip labels only (X5Q-05) -- aria-label stays the literal accessible name; these must never contradict it.
  tooltipToLight: string
  tooltipToDark: string
}

export interface MetaCopy {
  title: string
  description: string
  siteUrl: string
  ogImageUrl: string
}

export interface SiteCopy {
  meta: MetaCopy
  themeToggle: ThemeToggleCopy
  hero: HeroCopy
  problem: ProblemCopy
  howItWorks: HowItWorksCopy
  zeroCounters: ZeroCountersCopy
  dashboard: DashboardCopy
  quickstart: QuickstartCopy
  transport: TransportCopy
  requirements: RequirementsCopy
  faq: FaqCopy
  mission: MissionCopy
  closingCallToAction: ClosingCallToActionCopy
  footer: FooterCopy
}
