import type { HowItWorksCopy } from '../types'

export const howItWorks: HowItWorksCopy = {
  heading: 'The disk file is the buffer',
  lead: 'No cloud, no queue, no magic -- just a file that never stops growing.',
  paragraphs: [
    'OBS writes the service to a local .ts file and never talks to the network itself. A small pusher service tails that growing file and sends it on to your relay.',
    'If the connection drops, the pusher does not lose its place. It resumes from the exact byte offset it left off at, and sends faster than realtime until it has caught back up -- so the YouTube DVR stays gapless even after a multi-minute outage.',
    'Nothing is ever skipped, and nothing is ever reordered. The pusher reads the file strictly in consecutive byte order, which is what makes the output gapless in the first place.',
  ],
  flowNodes: [
    {
      id: 'obs',
      label: 'OBS',
      description: 'Records the service, never touches the network.',
      emphasised: false,
    },
    {
      id: 'local-file',
      label: 'local .ts file',
      description: 'The buffer. Keeps growing no matter what breaks downstream.',
      emphasised: true,
    },
    {
      id: 'pusher',
      label: 'pusher',
      description: 'Tails the file from the exact byte it left off at.',
      emphasised: false,
    },
    {
      id: 'transport',
      label: 'tcp or srt',
      description: 'Carries the bytes to the relay over the network.',
      emphasised: false,
    },
    {
      id: 'relay',
      label: 'relay VPS',
      description: 'Receives the stream and fans it out.',
      emphasised: false,
    },
    {
      id: 'youtube',
      label: 'YouTube',
      description: 'Your viewers watch here, gap-free.',
      emphasised: false,
    },
  ],
}
