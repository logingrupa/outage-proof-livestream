import type { FooterCopy } from '../types'

export const footer: FooterCopy = {
  licencePrefix: 'Licensed under the ',
  licenceLinkLabel: 'GNU Affero General Public License v3.0 (AGPL-3.0)',
  // D-26: links to the repository's own LICENSE file, not the external
  // licence site -- one mention, one link, pointed at the source of truth.
  licenceHref: 'https://github.com/logingrupa/outage-proof-livestream/blob/main/LICENSE',
  licenceSuffix: '.',
  repositoryLabel: 'GitHub',
  repositoryHref: 'https://github.com/logingrupa/outage-proof-livestream',
  attribution: 'Made by LOGINGRUPA Ltd.',
}
