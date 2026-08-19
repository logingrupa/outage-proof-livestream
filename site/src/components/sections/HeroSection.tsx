import { Button } from '@/components/ui/button'
import ScreenshotWithHotspots from '@/components/ScreenshotWithHotspots'
import { siteCopy } from '@/copy'
import { findShot } from '@/lib/shots'

const HERO_IMAGE_SIZES = '(min-width: 1024px) 840px, 92vw'

// D-01: exactly one loud CTA on the page. The primary button carries the
// accent; the secondary is deliberately quiet -- a ghost/text-only link.
//
// The hero carries the catch-up screenshot (the one state that argues the
// whole product) so the software is visible before any scrolling. It is shown
// here and NOT repeated in the gallery below.
export default function HeroSection() {
  const { hero, dashboard } = siteCopy
  const catchingUpShot = findShot(dashboard.shots, 'catchingUp')

  return (
    <section
      id="hero"
      aria-labelledby="hero-heading"
      className="mx-auto flex max-w-5xl flex-col items-start gap-8 px-6 py-20 sm:py-28"
    >
      <h1
        id="hero-heading"
        className="text-5xl font-semibold tracking-tight text-balance sm:text-6xl lg:text-7xl"
      >
        {hero.headline}
      </h1>
      <p className="max-w-2xl text-lg leading-relaxed text-muted-foreground sm:text-xl">
        {hero.subheadline}
      </p>
      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap items-center gap-6">
          <Button
            asChild
            size="lg"
            className="h-12 px-8 text-base font-semibold shadow-lg shadow-primary/25 transition-shadow hover:shadow-xl hover:shadow-primary/40"
          >
            <a href={hero.primaryCallToAction.href}>{hero.primaryCallToAction.label}</a>
          </Button>
          <Button asChild variant="ghost" size="sm" className="text-muted-foreground/80">
            <a href={hero.secondaryCallToAction.href}>{hero.secondaryCallToAction.label}</a>
          </Button>
        </div>
        <p className="text-sm text-muted-foreground">{hero.ctaMicrocopy}</p>
      </div>

      <figure className="mt-6 flex w-full flex-col gap-3">
        <ScreenshotWithHotspots shot={catchingUpShot} sizes={HERO_IMAGE_SIZES} priority />
        <figcaption className="text-sm text-muted-foreground">{hero.screenshotCaption}</figcaption>
      </figure>
    </section>
  )
}
