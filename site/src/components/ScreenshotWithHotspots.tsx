import ScreenshotFrame from '@/components/ScreenshotFrame'
import ScreenshotHotspot from '@/components/ScreenshotHotspot'
import { shotImages } from '@/data/shotImages'
import type { DashboardShot } from '@/copy/types'

interface ScreenshotWithHotspotsProps {
  shot: DashboardShot
  sizes: string
  // Above-the-fold shots must not lazy-load; gallery shots should.
  priority?: boolean
}

// The one place a captured dashboard state becomes pixels -- used by both the
// hero and the gallery so the framing, sizing and hotspot behaviour can never
// drift apart between them.
export default function ScreenshotWithHotspots({ shot, sizes, priority = false }: ScreenshotWithHotspotsProps) {
  const image = shotImages[shot.id]

  return (
    <ScreenshotFrame>
      <div className="relative">
        <img
          src={image.large}
          srcSet={`${image.small} 420w, ${image.large} 840w`}
          sizes={sizes}
          width={image.width}
          height={image.height}
          loading={priority ? 'eager' : 'lazy'}
          fetchPriority={priority ? 'high' : 'auto'}
          decoding="async"
          alt={shot.imageAlt}
          className="block h-auto w-full"
        />
        {shot.hotspots.map((hotspot) => (
          <ScreenshotHotspot key={hotspot.label} hotspot={hotspot} />
        ))}
      </div>
    </ScreenshotFrame>
  )
}
