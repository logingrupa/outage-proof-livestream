import { readFileSync } from 'node:fs'
import path from 'node:path'
import { SITE_ROOT, pass, fail } from './_shared.mjs'
import { oklchContrastRatio } from './_colorContrast.mjs'

export const name = 'accentContrastMeetsWcag'
const CSS_PATH = path.join(SITE_ROOT, 'src', 'index.css')
const AA_FLOOR = 4.5

const THEMES = [
  { label: 'light (:root)', blockPattern: /:root\s*\{([^}]*)\}/ },
  { label: 'dark (.dark)', blockPattern: /\.dark\s*\{([^}]*)\}/ },
]
const REQUIRED_VARIABLES = ['primary', 'primary-foreground', 'background', 'foreground']

function extractVariable(blockText, variableName) {
  const match = blockText.match(new RegExp(`--${variableName}:\\s*oklch\\(([^)]*)\\)`))
  if (!match) return null
  return match[1].trim()
}

function readThemeVariables(css, theme) {
  const blockMatch = css.match(theme.blockPattern)
  if (!blockMatch) throw new Error(`could not find a "${theme.label}" block in src/index.css`)
  const values = {}
  for (const variableName of REQUIRED_VARIABLES) {
    const value = extractVariable(blockMatch[1], variableName)
    if (!value) throw new Error(`"${theme.label}" block has no oklch --${variableName} declaration`)
    values[variableName] = value
  }
  return values
}

// Asserts, per theme: primary-foreground on primary, and primary on
// background, both at or above 4.5:1 -- the accent is used for icons and
// small numerals, not only large type, so the stricter floor applies
// uniformly (D-21). Prints every computed ratio to two decimals on the PASS
// line so the numbers are captured in build output for the SUMMARY.
export function run() {
  const css = readFileSync(CSS_PATH, 'utf8')
  const measurements = []

  for (const theme of THEMES) {
    const variables = readThemeVariables(css, theme)
    const foregroundOnPrimary = oklchContrastRatio(variables['primary-foreground'], variables.primary)
    const primaryOnBackground = oklchContrastRatio(variables.primary, variables.background)

    measurements.push({ theme: theme.label, pair: 'primary-foreground on primary', ratio: foregroundOnPrimary })
    measurements.push({ theme: theme.label, pair: 'primary on background', ratio: primaryOnBackground })
  }

  const failing = measurements.filter((entry) => entry.ratio < AA_FLOOR)
  const summary = measurements
    .map((entry) => `${entry.theme} ${entry.pair}=${entry.ratio.toFixed(2)}:1`)
    .join(', ')

  if (failing.length > 0) {
    return fail(`below the ${AA_FLOOR}:1 floor: ${failing.map((entry) => `${entry.theme} ${entry.pair}=${entry.ratio.toFixed(2)}:1`).join(', ')} (all measured: ${summary})`)
  }
  return pass(`all pairs clear ${AA_FLOOR}:1 -- ${summary}`)
}
