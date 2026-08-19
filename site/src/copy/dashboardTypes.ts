// Split out of types.ts to keep that file under its 150-line budget --
// same convention as every other copy type, just in its own file.
export interface DashboardHotspot {
  // Percentage position against the cropped screenshot's own pixels (X5Q-09v) -- verified visually, never trusted from arithmetic alone.
  xPercent: number
  yPercent: number
  label: string
  title: string
  sentence: string
}

// One captured dashboard state. `id` selects the imported image pair in the
// gallery component; copy never holds asset paths.
export interface DashboardShot {
  id: 'catchingUp' | 'streaming' | 'finished'
  title: string
  blurb: string
  imageAlt: string
  hotspots: DashboardHotspot[]
}

export interface DashboardFigure {
  // `id` selects the measured value from src/data/serviceFigures.ts -- labels
  // live in copy, figures live with the evidence, so no number is ever typed
  // twice.
  id: 'duration' | 'delivered' | 'undelivered' | 'peakBehind' | 'outages' | 'sent'
  label: string
  detail: string
}

export interface DashboardChartCopy {
  heading: string
  lead: string
  delayLegend: string
  sendLegend: string
  peakAnnotation: string
  recoveredAnnotation: string
  caption: string
}

export interface DashboardFiguresCopy {
  heading: string
  lead: string
  items: DashboardFigure[]
}

export interface DashboardCopy {
  heading: string
  lead: string
  caption: string
  shots: DashboardShot[]
  chart: DashboardChartCopy
  figures: DashboardFiguresCopy
}
