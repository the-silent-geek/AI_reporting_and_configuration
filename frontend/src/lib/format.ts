import type { BatchStatus } from './types'

const dateTime = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' })
const date = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' })

export const fmtDateTime = (iso: string | null | undefined) => (iso ? dateTime.format(new Date(iso)) : '—')
export const fmtDate = (iso: string | null | undefined) => (iso ? date.format(new Date(iso)) : '—')

export function fmtRelative(iso: string) {
  const s = (Date.now() - new Date(iso).getTime()) / 1000
  if (s < 45) return 'just now'
  if (s < 3600) return `${Math.round(s / 60)} min ago`
  if (s < 86400) return `${Math.round(s / 3600)} h ago`
  return fmtDate(iso)
}

export function fmtBytes(n: number) {
  if (n < 1024) return `${n} B`
  const units = ['KB', 'MB', 'GB']
  let i = -1
  do { n /= 1024; i++ } while (n >= 1024 && i < units.length - 1)
  return `${n.toFixed(n < 10 ? 1 : 0)} ${units[i]}`
}

export const STATUS_LABEL: Record<BatchStatus, string> = {
  UPLOADED: 'Uploaded',
  EXTRACTING: 'Extracting',
  MAPPING_REVIEW: 'Mapping review',
  VALIDATING: 'Validating',
  READY_TO_COMMIT: 'Ready to commit',
  COMMITTED: 'Committed',
  NEEDS_REVIEW: 'Needs review',
  FAILED: 'Failed',
}

/** Happy path, in order (used by the progress stepper). */
export const STATUS_FLOW: BatchStatus[] = [
  'UPLOADED', 'EXTRACTING', 'MAPPING_REVIEW', 'VALIDATING', 'READY_TO_COMMIT', 'COMMITTED',
]

export const isInProgress = (s: BatchStatus) => s === 'EXTRACTING' || s === 'VALIDATING' || s === 'UPLOADED'

export function greeting() {
  const h = new Date().getHours()
  return h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening'
}

export const initials = (name: string) =>
  name.split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0]!.toUpperCase()).join('')

export const titleCase = (s: string) => s.toLowerCase().replace(/(^|_)(\w)/g, (_, sp, c) => (sp ? ' ' : '') + c.toUpperCase())
