import ScreenshotWithHotspots from '@/components/ScreenshotWithHotspots'
import { siteCopy } from '@/copy'
import type { DashboardShot } from '@/copy/types'

const IMAGE_SIZES = '(min-width: 1024px) 840px, 90vw'

interface DashboardGalleryProps {
  shots: readonly DashboardShot[]
}

export default function DashboardGallery({ shots }: DashboardGalleryProps) {
  return (
    <div className="flex flex-col gap-14">
      {shots.map((shot) => (
        <figure key={shot.id} className="flex flex-col gap-5">
          <figcaption className="flex flex-col gap-2">
            <h3 className="text-xl font-semibold tracking-tight">{shot.title}</h3>
            <p className="max-w-2xl text-muted-foreground">{shot.blurb}</p>
          </figcaption>
          <ScreenshotWithHotspots shot={shot} sizes={IMAGE_SIZES} />
          <p className="text-sm text-muted-foreground">{siteCopy.dashboard.caption}</p>
        </figure>
      ))}
    </div>
  )
}
