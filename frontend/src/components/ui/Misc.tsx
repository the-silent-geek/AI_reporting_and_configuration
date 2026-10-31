import clsx from 'clsx'
import { motion } from 'motion/react'
import type { LucideIcon } from 'lucide-react'
import type { ReactNode } from 'react'
import { STATUS_LABEL, initials } from '../../lib/format'
import type { BatchStatus } from '../../lib/types'

export function Card({ className, children }: { className?: string; children: ReactNode }) {
  return <div className={clsx('rounded-xl border border-border bg-surface', className)}>{children}</div>
}

export function Badge({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <span className={clsx('inline-flex items-center gap-1 rounded-md border border-border px-1.5 py-0.5',
      'text-[11px] font-medium uppercase tracking-wide text-fg-muted', className)}>
      {children}
    </span>
  )
}

/* Status is mostly shape + tone, not colour: a dot that pulses while work is running. */
const STATUS_TONE: Record<BatchStatus, string> = {
  UPLOADED: 'bg-fg-subtle',
  EXTRACTING: 'bg-fg',
  MAPPING_REVIEW: 'bg-warning',
  VALIDATING: 'bg-fg',
  READY_TO_COMMIT: 'bg-fg',
  COMMITTED: 'bg-success',
  NEEDS_REVIEW: 'bg-warning',
  FAILED: 'bg-danger',
}
export function StatusBadge({ status }: { status: BatchStatus }) {
  const live = status === 'EXTRACTING' || status === 'VALIDATING'
  return (
    <span className="inline-flex items-center gap-2 rounded-full border border-border bg-surface px-2.5 py-0.5 text-xs font-medium whitespace-nowrap">
      <span className="relative flex size-1.5">
        {live && <span className={clsx('absolute inline-flex size-full animate-ping rounded-full opacity-60', STATUS_TONE[status])} />}
        <span className={clsx('relative inline-flex size-1.5 rounded-full', STATUS_TONE[status])} />
      </span>
      {STATUS_LABEL[status]}
    </span>
  )
}

export function ProgressBar({ value, className }: { value: number; className?: string }) {
  return (
    <div className={clsx('h-1 w-full overflow-hidden rounded-full bg-muted', className)}
         role="progressbar" aria-valuenow={value} aria-valuemin={0} aria-valuemax={100}>
      <motion.div className="h-full rounded-full bg-fg" initial={false}
                  animate={{ width: `${Math.max(0, Math.min(100, value))}%` }}
                  transition={{ type: 'spring', stiffness: 120, damping: 24 }} />
    </div>
  )
}

export function Skeleton({ className }: { className?: string }) {
  return <div className={clsx('skeleton', className)} />
}

export function Avatar({ name, className }: { name: string; className?: string }) {
  return (
    <span className={clsx('inline-flex size-8 shrink-0 items-center justify-center rounded-full bg-fg text-[11px] font-semibold text-bg', className)}>
      {initials(name)}
    </span>
  )
}

export function EmptyState({ icon: Icon, title, children, action }: {
  icon: LucideIcon; title: string; children?: ReactNode; action?: ReactNode
}) {
  return (
    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}
                className="flex flex-col items-center justify-center px-6 py-16 text-center">
      <div className="mb-4 flex size-12 items-center justify-center rounded-xl border border-border bg-subtle">
        <Icon className="size-5 text-fg-muted" strokeWidth={1.5} />
      </div>
      <h3 className="text-sm font-semibold">{title}</h3>
      {children && <p className="mt-1 max-w-sm text-sm text-fg-muted">{children}</p>}
      {action && <div className="mt-5">{action}</div>}
    </motion.div>
  )
}

export function PageHeader({ title, description, actions }: {
  title: string; description?: ReactNode; actions?: ReactNode
}) {
  return (
    <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div className="min-w-0">
        <h1 className="text-xl font-semibold tracking-tight sm:text-2xl">{title}</h1>
        {description && <p className="mt-1 text-sm text-fg-muted">{description}</p>}
      </div>
      {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
    </div>
  )
}

/** Logo mark + wordmark. */
export function Brand({ compact, inverted }: { compact?: boolean; inverted?: boolean }) {
  return (
    <span className="inline-flex items-center gap-2.5">
      <span className={clsx('flex size-8 shrink-0 items-center justify-center rounded-lg',
        inverted ? 'bg-white text-zinc-950' : 'bg-fg text-bg')}>
        <svg viewBox="0 0 32 32" className="size-5" fill="currentColor" aria-hidden>
          <rect x="7" y="17" width="4.5" height="9" rx="1.2" /><rect x="13.75" y="11" width="4.5" height="15" rx="1.2" />
          <rect x="20.5" y="6" width="4.5" height="20" rx="1.2" />
        </svg>
      </span>
      {!compact && <span className="text-[15px] font-semibold tracking-tight whitespace-nowrap">Reporting Studio</span>}
    </span>
  )
}
