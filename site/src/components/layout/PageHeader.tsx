import BrandMark from '@/components/BrandMark'
import ThemeToggle from '@/components/ThemeToggle'

// Deliberately minimal (D-01): the mark + wordmark lockup and the theme
// toggle. No navigation, no GitHub button -- nothing competes with the
// hero's one CTA. The wordmark reads the product name a person reads
// everywhere else (D-19); the bare slug survives only in URLs and paths.
export default function PageHeader() {
  return (
    <header className="mx-auto flex max-w-5xl items-center justify-between px-6 py-6">
      <span className="flex items-center gap-2 text-sm font-medium tracking-tight text-foreground">
        <BrandMark size={20} className="text-foreground" />
        Outage-Proof Livestream
      </span>
      <ThemeToggle />
    </header>
  )
}
