import { readDistHtml, pass, fail } from './_shared.mjs'

export const name = 'themeScriptOrder'
const THEME_SCRIPT_MARKER = 'id="theme-init"'

export function run() {
  const html = readDistHtml()
  const themeScriptIndex = html.indexOf(THEME_SCRIPT_MARKER)
  const firstStylesheetIndex = html.indexOf('<link rel="stylesheet"')
  const firstModuleScriptIndex = html.indexOf('<script type="module"')

  if (themeScriptIndex === -1) {
    return fail(`no inline theme script found (looked for ${THEME_SCRIPT_MARKER})`)
  }
  if (firstStylesheetIndex !== -1 && themeScriptIndex > firstStylesheetIndex) {
    return fail('inline theme script appears AFTER the first stylesheet -- the flash guard is too late')
  }
  if (firstModuleScriptIndex !== -1 && themeScriptIndex > firstModuleScriptIndex) {
    return fail('inline theme script appears AFTER the first module script -- the flash guard is too late')
  }
  return pass('inline theme script runs before the first stylesheet and the first module script')
}
