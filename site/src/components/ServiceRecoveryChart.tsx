import { recoveryArc } from '@/data/recoveryArc'
import { siteCopy } from '@/copy'
import {
  buildAreaPath,
  buildLinePath,
  formatMinutesAndSeconds,
  indexOfMaximum,
  pointAt,
  scaleForSeries,
} from '@/lib/chartGeometry'

const PLOT_WIDTH = 652
const PLOT_HEIGHT = 168
const OFFSET_X = 52
const OFFSET_Y = 18
const DELAY_INDEX = 1
const SEND_INDEX = 2

// The delay curve is the argument, so it gets the filled area and the accent.
// The upload rate rides along as context on its own scale -- deliberately
// without a numeric axis, because throughput figures are not claims this page
// makes in copy (they are only ever legible inside the screenshots).
export default function ServiceRecoveryChart() {
  const { chart } = siteCopy.dashboard
  const delayScale = scaleForSeries(recoveryArc, DELAY_INDEX, PLOT_WIDTH, PLOT_HEIGHT)
  const sendScale = scaleForSeries(recoveryArc, SEND_INDEX, PLOT_WIDTH, PLOT_HEIGHT)

  const peakIndex = indexOfMaximum(recoveryArc, DELAY_INDEX)
  const peak = pointAt(recoveryArc, DELAY_INDEX, peakIndex, delayScale)
  const lastIndex = recoveryArc.length - 1
  const end = pointAt(recoveryArc, DELAY_INDEX, lastIndex, delayScale)

  const peakSeconds = recoveryArc[peakIndex][DELAY_INDEX]
  const endSeconds = recoveryArc[lastIndex][DELAY_INDEX]
  const totalSeconds = recoveryArc[lastIndex][0]

  return (
    <figure className="rounded-xl border border-border bg-card/40 p-5 sm:p-6">
      <svg
        viewBox="0 0 720 236"
        className="block h-auto w-full"
        role="img"
        aria-label={`${chart.delayLegend}: rises to ${formatMinutesAndSeconds(peakSeconds)} behind live, then falls back to ${formatMinutesAndSeconds(endSeconds)} over ${formatMinutesAndSeconds(totalSeconds)}.`}
      >
        <g transform={`translate(${OFFSET_X} ${OFFSET_Y})`}>
          <line x1="0" y1={PLOT_HEIGHT} x2={PLOT_WIDTH} y2={PLOT_HEIGHT} className="stroke-border" strokeWidth="1" />
          <line x1="0" y1="0" x2={PLOT_WIDTH} y2="0" className="stroke-border/50" strokeWidth="1" strokeDasharray="3 5" />

          <path d={buildAreaPath(recoveryArc, DELAY_INDEX, delayScale)} className="fill-primary/15" />
          <path
            d={buildLinePath(recoveryArc, SEND_INDEX, sendScale)}
            className="stroke-sky-500/45"
            strokeWidth="1.5"
            fill="none"
            strokeDasharray="4 4"
          />
          <path
            d={buildLinePath(recoveryArc, DELAY_INDEX, delayScale)}
            className="motion-safe:animate-[chart-draw_1.4s_ease-out_both] stroke-primary"
            strokeWidth="2.5"
            fill="none"
            strokeLinejoin="round"
            pathLength={1}
            strokeDasharray="1"
          />

          <circle cx={peak.x} cy={peak.y} r="4" className="fill-primary" />
          <circle cx={end.x} cy={end.y} r="4" className="fill-primary" />
        </g>

        <text x={OFFSET_X - 8} y={OFFSET_Y + 5} textAnchor="end" className="fill-muted-foreground text-[11px]">
          {formatMinutesAndSeconds(peakSeconds)}
        </text>
        <text x={OFFSET_X - 8} y={OFFSET_Y + PLOT_HEIGHT + 4} textAnchor="end" className="fill-muted-foreground text-[11px]">
          0s
        </text>
        <text x={OFFSET_X + peak.x} y={OFFSET_Y + peak.y - 12} textAnchor="middle" className="fill-foreground text-[11px] font-medium">
          {chart.peakAnnotation}
        </text>
        <text x={OFFSET_X + PLOT_WIDTH} y={OFFSET_Y + end.y - 14} textAnchor="end" className="fill-foreground text-[11px] font-medium">
          {chart.recoveredAnnotation}
        </text>
        <text x={OFFSET_X} y={OFFSET_Y + PLOT_HEIGHT + 22} className="fill-muted-foreground text-[11px]">
          0m
        </text>
        <text x={OFFSET_X + PLOT_WIDTH} y={OFFSET_Y + PLOT_HEIGHT + 22} textAnchor="end" className="fill-muted-foreground text-[11px]">
          {formatMinutesAndSeconds(totalSeconds)}
        </text>
      </svg>

      <figcaption className="mt-4 flex flex-col gap-3 text-sm text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
        <span className="flex flex-wrap items-center gap-4">
          <span className="flex items-center gap-2">
            <span className="h-0.5 w-5 rounded bg-primary" />
            {chart.delayLegend}
          </span>
          <span className="flex items-center gap-2">
            <span className="h-0.5 w-5 rounded bg-sky-500/60" />
            {chart.sendLegend}
          </span>
        </span>
        <span>{chart.caption}</span>
      </figcaption>
    </figure>
  )
}
