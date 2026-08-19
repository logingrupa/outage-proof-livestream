import type { DashboardShot } from '@/copy/types'
import catchingUp840 from '@/assets/dashboard-catching-up-840w.png'
import catchingUp420 from '@/assets/dashboard-catching-up-420w.png'
import streaming840 from '@/assets/dashboard-streaming-840w.png'
import streaming420 from '@/assets/dashboard-streaming-420w.png'
import finished840 from '@/assets/dashboard-finished-840w.png'
import finished420 from '@/assets/dashboard-finished-420w.png'

export interface ShotImage {
  small: string
  large: string
  width: number
  height: number
}

// Recorded intrinsic dimensions of each shipped crop, so nothing shifts while
// the images load. The finished card is a shorter crop than the two live
// states -- it has no chart panel beneath it.
export const shotImages: Record<DashboardShot['id'], ShotImage> = {
  catchingUp: { small: catchingUp420, large: catchingUp840, width: 840, height: 490 },
  streaming: { small: streaming420, large: streaming840, width: 840, height: 490 },
  finished: { small: finished420, large: finished840, width: 840, height: 301 },
}
