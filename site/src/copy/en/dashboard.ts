import type { DashboardCopy } from '../types'

// D-05/noFabricatedProof: every figure here describes ONE real service on the
// authors' own dashboard, attributed exactly that way -- never an average, a
// rate, or a guarantee. Throughput numbers are legible inside the screenshots
// themselves but are never quoted as copy (X5Q-09vi).
export const dashboard: DashboardCopy = {
  heading: 'One real service, not a mockup',
  lead: 'These are our own screens from a single Sunday, replayed from that service’s own logs. One of them is the whole product in one picture: the moment after the upload path failed, with the backlog draining away.',
  caption: 'Hover, tap or focus a dot to read what it shows.',
  shots: [
    {
      id: 'catchingUp',
      title: 'Catching up after an outage',
      blurb:
        'The upload path had just failed and recovered. The recording never stopped, so nothing was lost — the pusher simply sends faster than realtime until the backlog is gone.',
      imageAlt:
        'Dashboard while catching up: 34 seconds behind live and falling, with the note "caught up 26s in last minute", the send line above the record line, and the delay curve sloping down.',
      hotspots: [
        {
          xPercent: 63,
          yPercent: 31.6,
          label: 'Delay behind live',
          title: 'How far behind live it is',
          sentence:
            'The stream is running behind the room by this much. It is a number that shrinks on its own — nothing here is lost, only late.',
        },
        {
          xPercent: 38,
          yPercent: 42.5,
          label: 'Catch-up progress in the last minute',
          title: 'The backlog draining',
          sentence:
            'Ground regained since the previous minute. As long as this keeps counting, the gap is closing without anyone touching anything.',
        },
        {
          xPercent: 47,
          yPercent: 69,
          label: 'Delay curve over the last five minutes',
          title: 'The recovery, drawn',
          sentence:
            'The curve rose when the connection failed and slopes back down as the pusher catches up. This is the whole promise in one line.',
        },
      ],
    },
    {
      id: 'streaming',
      title: 'Streaming normally',
      blurb:
        'The steady state for most of a service: a small, deliberate delay held level, everything recorded already delivered.',
      imageAlt:
        'Dashboard streaming normally: 10 seconds behind live and holding steady, 100% sent, and the recording file marked as growing.',
      hotspots: [
        {
          xPercent: 62.5,
          yPercent: 31.6,
          label: 'Steady delay behind live',
          title: 'A deliberate head start',
          sentence:
            'A small delay is kept on purpose. It is the cushion that absorbs a hiccup before anyone watching would notice one.',
        },
        {
          xPercent: 46.4,
          yPercent: 12.7,
          label: 'Share of the recording already sent',
          title: 'Nothing waiting in line',
          sentence:
            'Everything the church PC has recorded so far has already reached the relay.',
        },
        {
          xPercent: 40.5,
          yPercent: 88.8,
          label: 'Recording file being followed',
          title: 'The file is the buffer',
          sentence:
            'The pusher follows the growing recording on disk. That file, not the network, is the source of truth.',
        },
      ],
    },
    {
      id: 'finished',
      title: 'Service finished',
      blurb:
        'How a service ends when it goes right: everything recorded has been delivered, and the next recording is already detected.',
      imageAlt:
        'Dashboard after the service: "Service Finished", total session duration 2h 42m, undelivered 0.0 MB, and a new recording detected.',
      hotspots: [
        {
          xPercent: 71.4,
          yPercent: 59.8,
          label: 'Session duration and undelivered bytes',
          title: 'Nothing left behind',
          sentence:
            'This service ran 2h 42m and finished with 0.0 MB undelivered — everything the church PC recorded reached the relay.',
        },
        {
          xPercent: 68.5,
          yPercent: 77.4,
          label: 'Start control for the next recording',
          title: 'One click for the next service',
          sentence:
            'Once a new recording is detected, starting the push is a single click — no file wrangling.',
        },
      ],
    },
  ],
  chart: {
    heading: 'What an outage actually looks like',
    lead: 'Thirteen minutes from that same service, drawn from the delay readings the pusher wrote to its own log. The upload path degraded, the backlog grew, and then it drained — with every byte still arriving in order.',
    delayLegend: 'delay behind live',
    sendLegend: 'upload rate',
    peakAnnotation: 'worst point',
    recoveredAnnotation: 'back in band',
    caption:
      'One service, 2026-08-16. The vertical axis starts at zero — the curve is not exaggerated by a cropped scale.',
  },
  figures: {
    heading: 'The same service, in numbers',
    lead: 'Read from the pusher’s own state file and logs at the end of that service.',
    items: [
      {
        id: 'duration',
        label: 'Session duration',
        detail: 'Start to clean finish, unattended.',
      },
      {
        id: 'delivered',
        label: 'Delivered',
        detail: 'Every byte the church PC recorded.',
      },
      {
        id: 'undelivered',
        label: 'Undelivered at finish',
        detail: 'What was left stranded on disk. Nothing.',
      },
      { id: 'sent', label: 'Sent', detail: 'Share of the recording that reached the relay.' },
      {
        id: 'peakBehind',
        label: 'Worst point behind live',
        detail: 'How far the backlog grew before it drained.',
      },
      {
        id: 'outages',
        label: 'Connection recoveries',
        detail: 'Times the upload path dropped and resumed by itself.',
      },
    ],
  },
}
