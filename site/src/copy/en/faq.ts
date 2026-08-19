import type { FaqCopy } from '../types'

export const faq: FaqCopy = {
  heading: 'Questions a volunteer actually asks',
  lead: 'Straight answers, no jargon.',
  items: [
    {
      question: 'What happens if the internet dies mid-service?',
      answer:
        'Nothing is lost. OBS keeps recording to the local .ts file on the church PC the whole time, because it never depends on the network. Once the connection comes back, the pusher resumes sending from the exact byte it left off at and catches up faster than realtime.',
    },
    {
      question: 'Will the viewer see a gap in the stream?',
      answer:
        'No. Because the pusher resumes from the exact byte offset and sends faster than realtime to catch up, the YouTube DVR stays gapless even after a multi-minute outage. Viewers may notice the stream briefly speed up while it catches up, but no content is skipped or reordered.',
    },
    {
      question: 'Do I need a special router or a bonded internet connection?',
      answer:
        'No. The relay only needs an Ubuntu VPS with a public IP -- no bonded WAN, no special router, and no tunnel required. The church PC just needs Windows 10 or newer, PowerShell 7.4+, and ffmpeg 7.1.x on PATH.',
    },
    {
      question: 'What does this cost?',
      answer:
        'The software itself is free and stays free -- it is licensed under the AGPL-3.0, so there is no licence fee and no lock-in. The only ongoing cost is whatever you already pay for an Ubuntu VPS with a public IP to run the relay.',
    },
    {
      question: 'Is my YouTube stream key safe?',
      answer:
        'Your stream key lives only in a chmod-600 environment file on your own VPS, set by you during setup. It is never committed to this repository and never sent anywhere except from your relay to YouTube.',
    },
    {
      question: 'What if the church PC reboots mid-week or before a service?',
      answer:
        'install.ps1 registers a Windows Scheduled Task that starts the supervisor automatically at boot. It comes up idle and streams nothing until an operator explicitly presses Start on the dashboard, so a reboot never starts an unattended stream by itself.',
    },
    {
      question: 'How do I know it is actually working?',
      answer:
        'Once the pusher is running, a live status dashboard is served at http://localhost:8787 -- plain HTML and JS, no build step, served directly by the pusher process itself, so you can see its status at a glance.',
    },
    {
      question: 'Is this a polished, supported product?',
      answer:
        'No -- it is church-tech tooling extracted from one production deployment, not a polished product. It assumes a specific workflow (OBS records to disk, a pusher tails that file, a VPS relay fans out to YouTube) and it has sharp edges. Read the code before you trust it with a service you cannot afford to lose.',
    },
  ],
}
