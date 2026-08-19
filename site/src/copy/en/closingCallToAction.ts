import type { ClosingCallToActionCopy } from '../types'

// The label here is deliberately different from the hero's primary CTA label:
// D-01 allows exactly one loud CTA, and singleLoudCallToAction enforces that
// the hero's label appears exactly once in the rendered text.
export const closingCallToAction: ClosingCallToActionCopy = {
  heading: 'Your next service does not have to be a gamble',
  lines: [
    'If your stream has ever cut out mid-sermon, you already know the feeling — the part nobody will ever hear is gone, and there is nothing to do about it afterwards.',
    'There is nothing to buy and nothing to sign. Take it, run it on the church PC, and let the recording on disk be the thing you trust.',
  ],
  callToAction: {
    label: 'Set it up on your PC',
    href: '#quickstart',
  },
  microcopy: 'Free, open source, and yours to keep.',
}
