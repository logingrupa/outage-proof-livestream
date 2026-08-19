// Pure geometry for the recovery chart: numbers in, path strings out. Kept
// out of the component so the drawing code stays declarative and this stays
// trivially checkable.

export interface ChartScale {
  minX: number
  maxX: number
  maxY: number
  width: number
  height: number
}

export function scaleForSeries(
  points: readonly (readonly number[])[],
  valueIndex: number,
  width: number,
  height: number,
): ChartScale {
  const xs = points.map((point) => point[0])
  const ys = points.map((point) => point[valueIndex])
  return {
    minX: Math.min(...xs),
    maxX: Math.max(...xs),
    // Always measured from zero: a truncated y-axis would exaggerate the fall.
    maxY: Math.max(...ys),
    width,
    height,
  }
}

function projectX(x: number, scale: ChartScale): number {
  const span = scale.maxX - scale.minX
  if (span <= 0) return 0
  return ((x - scale.minX) / span) * scale.width
}

function projectY(y: number, scale: ChartScale): number {
  if (scale.maxY <= 0) return scale.height
  return scale.height - (y / scale.maxY) * scale.height
}

export function buildLinePath(
  points: readonly (readonly number[])[],
  valueIndex: number,
  scale: ChartScale,
): string {
  return points
    .map((point, index) => {
      const command = index === 0 ? 'M' : 'L'
      return `${command}${projectX(point[0], scale).toFixed(2)} ${projectY(point[valueIndex], scale).toFixed(2)}`
    })
    .join(' ')
}

// Closes the line down to the baseline so the area under the delay curve can
// be filled -- the filled mass IS the backlog, which is the point being made.
export function buildAreaPath(
  points: readonly (readonly number[])[],
  valueIndex: number,
  scale: ChartScale,
): string {
  if (points.length === 0) return ''
  const line = buildLinePath(points, valueIndex, scale)
  const lastX = projectX(points[points.length - 1][0], scale).toFixed(2)
  const firstX = projectX(points[0][0], scale).toFixed(2)
  return `${line} L${lastX} ${scale.height} L${firstX} ${scale.height} Z`
}

export function pointAt(
  points: readonly (readonly number[])[],
  valueIndex: number,
  index: number,
  scale: ChartScale,
): { x: number; y: number } {
  const point = points[index]
  return { x: projectX(point[0], scale), y: projectY(point[valueIndex], scale) }
}

export function indexOfMaximum(
  points: readonly (readonly number[])[],
  valueIndex: number,
): number {
  let best = 0
  for (let index = 1; index < points.length; index += 1) {
    if (points[index][valueIndex] > points[best][valueIndex]) best = index
  }
  return best
}

export function formatMinutesAndSeconds(totalSeconds: number): string {
  const minutes = Math.floor(totalSeconds / 60)
  const seconds = Math.round(totalSeconds % 60)
  if (minutes === 0) return `${seconds}s`
  return `${minutes}m ${String(seconds).padStart(2, '0')}s`
}
