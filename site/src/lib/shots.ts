import type { DashboardShot } from '@/copy/types'

// Fail loudly at build/prerender time rather than rendering a hero with a
// missing screenshot if a shot id is ever renamed in copy.
export function findShot(shots: readonly DashboardShot[], id: DashboardShot['id']): DashboardShot {
  const shot = shots.find((candidate) => candidate.id === id)
  if (!shot) throw new Error(`dashboard copy is missing the "${id}" shot`)
  return shot
}

export function excludeShot(
  shots: readonly DashboardShot[],
  id: DashboardShot['id'],
): readonly DashboardShot[] {
  return shots.filter((candidate) => candidate.id !== id)
}
