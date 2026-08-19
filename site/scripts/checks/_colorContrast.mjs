// Helper (leading underscore -- skipped by verify-build.mjs's discovery).
// Pure colour maths: no file I/O, no knowledge of dist/ or index.css. Parses
// an `oklch(L C H)` string, converts oklch -> oklab -> linear sRGB (Björn
// Ottosson's published matrices), computes WCAG relative luminance directly
// from the linear values, and derives a contrast ratio. Kept dependency-free
// and pure so accentContrastMeetsWcag.mjs stays a thin reader-and-asserter.
export function parseOklch(raw) {
  const match = raw.trim().match(/^([\d.]+)\s+([\d.]+)\s+([\d.]+)$/)
  if (!match) throw new Error(`could not parse oklch triple from "${raw}"`)
  const [, lightness, chroma, hue] = match
  return { l: Number(lightness), c: Number(chroma), h: Number(hue) }
}

function clamp01(value) {
  return Math.min(1, Math.max(0, value))
}

// oklch -> oklab: standard polar-to-rectangular conversion, hue in degrees.
function oklchToOklab({ l, c, h }) {
  const hueRadians = (h * Math.PI) / 180
  return { l, a: c * Math.cos(hueRadians), b: c * Math.sin(hueRadians) }
}

// oklab -> linear sRGB, per https://bottosson.github.io/posts/oklab/.
function oklabToLinearSrgb({ l, a, b }) {
  const l_ = l + 0.3963377774 * a + 0.2158037573 * b
  const m_ = l - 0.1055613458 * a - 0.0638541728 * b
  const s_ = l - 0.0894841775 * a - 1.2914855480 * b

  const lCubed = l_ ** 3
  const mCubed = m_ ** 3
  const sCubed = s_ ** 3

  return {
    r: clamp01(+4.0767416621 * lCubed - 3.3077115913 * mCubed + 0.2309699292 * sCubed),
    g: clamp01(-1.2684380046 * lCubed + 2.6097574011 * mCubed - 0.3413193965 * sCubed),
    b: clamp01(-0.0041960863 * lCubed - 0.7034186147 * mCubed + 1.7076147010 * sCubed),
  }
}

export function oklchStringToLinearSrgb(raw) {
  return oklabToLinearSrgb(oklchToOklab(parseOklch(raw)))
}

// WCAG relative luminance, computed directly from already-linear-light RGB
// (the oklab->linear-sRGB matrices above produce exactly the values this
// formula expects -- no separate gamma-decode step is needed).
export function relativeLuminance({ r, g, b }) {
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

export function contrastRatio(colorA, colorB) {
  const luminanceA = relativeLuminance(colorA)
  const luminanceB = relativeLuminance(colorB)
  const lighter = Math.max(luminanceA, luminanceB)
  const darker = Math.min(luminanceA, luminanceB)
  return (lighter + 0.05) / (darker + 0.05)
}

export function oklchContrastRatio(rawA, rawB) {
  return contrastRatio(oklchStringToLinearSrgb(rawA), oklchStringToLinearSrgb(rawB))
}
