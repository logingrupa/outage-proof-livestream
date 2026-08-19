// Measured facts from ONE service (2026-08-16), each traceable to a source:
//
//   duration    state/session.json + stats.json -- 9739.7s
//   delivered   stats.json TotalBytes -- 33,198,289,072 bytes
//   undelivered stats.json PendingBytes at clean end-of-service -- 0
//   sent        SentBytes / TotalBytes at end-of-service
//   peakBehind  worst logged "behind live" reading of the service -- 487.7s
//   outages     count of "Write succeeded after outage" log lines -- 4
//
// Values live here rather than in src/copy so a figure is never typed twice,
// and so the copy dictionary stays prose-only.
export const serviceFigures = {
  duration: '2h 42m',
  delivered: '33.2 GB',
  undelivered: '0.0 MB',
  sent: '100%',
  peakBehind: '8m 08s',
  outages: '4',
} as const

export type ServiceFigureId = keyof typeof serviceFigures
