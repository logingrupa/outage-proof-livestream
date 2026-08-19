import { readDistHtml, decodeAndNormalize, stripTagsToText, pass, fail } from './_shared.mjs'
import { faq } from '../../src/copy/en/faq.ts'

export const name = 'faqStructuredDataMatchesVisible'

const LD_JSON_PATTERN = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g
const FAQ_SECTION_PATTERN = /<section id="faq"[\s\S]*?<\/section>/
const QUESTION_HEADING_PATTERN = /<h3[^>]*>([\s\S]*?)<\/h3>/g

function extractJsonLdQuestionNames(html) {
  const names = new Set()
  for (const match of html.matchAll(LD_JSON_PATTERN)) {
    let parsed
    try {
      parsed = JSON.parse(match[1])
    } catch {
      continue
    }
    if (parsed['@type'] !== 'FAQPage') continue
    for (const entry of parsed.mainEntity ?? []) {
      names.add(decodeAndNormalize(entry.name))
    }
  }
  return names
}

function extractVisibleQuestions(html) {
  const sectionMatch = html.match(FAQ_SECTION_PATTERN)
  if (!sectionMatch) return new Set()
  const names = new Set()
  for (const match of sectionMatch[0].matchAll(QUESTION_HEADING_PATTERN)) {
    // The <h3> wraps the whole AccordionTrigger button, including its
    // chevron icon SVGs -- strip tags rather than assume one bare text node.
    names.add(stripTagsToText(match[1]))
  }
  return names
}

function setsEqual(a, b) {
  return a.size === b.size && [...a].every((value) => b.has(value))
}

function describeSet(set) {
  return `{${[...set].join(' | ')}}`
}

export function run() {
  const html = readDistHtml()
  const dictionaryQuestions = new Set(faq.items.map((item) => decodeAndNormalize(item.question)))
  const visibleQuestions = extractVisibleQuestions(html)
  const jsonLdQuestions = extractJsonLdQuestionNames(html)

  if (visibleQuestions.size === 0) {
    return fail('no <h3> question headings found inside <section id="faq">')
  }
  if (jsonLdQuestions.size === 0) {
    return fail('no FAQPage JSON-LD mainEntity questions found')
  }
  if (!setsEqual(dictionaryQuestions, visibleQuestions)) {
    return fail(
      `visible FAQ questions do not match the copy dictionary. dictionary=${describeSet(dictionaryQuestions)} visible=${describeSet(visibleQuestions)}`,
    )
  }
  if (!setsEqual(dictionaryQuestions, jsonLdQuestions)) {
    return fail(
      `FAQPage JSON-LD questions do not match the copy dictionary. dictionary=${describeSet(dictionaryQuestions)} jsonLd=${describeSet(jsonLdQuestions)}`,
    )
  }

  return pass(`${dictionaryQuestions.size} FAQ questions match exactly across the dictionary, visible accordion, and JSON-LD`)
}
