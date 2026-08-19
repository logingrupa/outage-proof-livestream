import type { MetaCopy } from '../types'

const SITE_URL = 'https://logingrupa.github.io/outage-proof-livestream/'

export const meta: MetaCopy = {
  title: 'Outage-Proof Livestream — Keep your church livestream on air',
  description:
    'A free, open-source Windows service that makes church livestreams outage-proof. OBS records to disk; a pusher resumes from the exact byte and catches up faster than realtime. Zero content lost.',
  siteUrl: SITE_URL,
  ogImageUrl: `${SITE_URL}og.png`,
}
