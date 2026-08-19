import type { RequirementsCopy } from '../types'

export const requirements: RequirementsCopy = {
  heading: 'What you need',
  groups: [
    {
      title: 'Church PC',
      items: ['Windows 10 or newer', 'PowerShell 7.4+', 'ffmpeg 7.1.x on PATH'],
    },
    {
      title: 'Relay',
      items: [
        'An Ubuntu VPS with a public IP',
        'No bonded WAN required',
        'No special router required',
        'No tunnel required',
      ],
    },
  ],
}
