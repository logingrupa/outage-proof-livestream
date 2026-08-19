import type { HeroCopy } from '../types'

// Locked verbatim (D-04) -- implement character for character, including the
// double hyphen. Do not convert it to an em dash.
export const hero: HeroCopy = {
  headline: 'Keep your church livestream on air when the internet drops',
  subheadline:
    'OBS records to a file on disk and never touches the network. This service pushes that file to your relay -- and when the connection dies, it picks up from the exact byte and catches up faster than realtime. Your viewers see a gap-free stream. You lose nothing.',
  primaryCallToAction: {
    label: 'Get it running',
    href: '#quickstart',
  },
  ctaMicrocopy: 'Two short setups below -- one on the church PC, one on your relay. No bonded WAN or special router required.',
  secondaryCallToAction: {
    label: 'View source',
    href: 'https://github.com/logingrupa/outage-proof-livestream',
  },
  screenshotCaption:
    'Our own dashboard during a real Sunday service, moments after the upload path failed: the backlog is draining and the stream is closing the gap by itself. Hover, tap or focus a dot to read what it shows.',
}
