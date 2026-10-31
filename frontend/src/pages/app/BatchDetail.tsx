import clsx from 'clsx'
import { AlertTriangle, ArrowLeft, BadgeCheck, Check, CheckCheck, Copy, FileSearch, GitCompare, Radio } from 'lucide-react'
import { AnimatePresence, motion } from 'motion/react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Button } from '../../components/ui/Button'
import { Dialog } from '../../components/ui/Dialog'
import { Card, EmptyState, ProgressBar, Skeleton, StatusBadge } from '../../components/ui/Misc'
import { useToast } from '../../components/ui/Toast'
import { ApiError, api, streamEvents } from '../../lib/api'
import { useApp } from '../../lib/appContext'
import { STATUS_FLOW, STATUS_LABEL, fmtBytes, fmtDate, fmtDateTime } from '../../lib/format'
import type { Batch, BatchEvent, BatchStatus } from '../../lib/types'

export function BatchDetail() {
  const { batchId = '' } = useParams()
  const { app, code, can } = useApp()
  const toast = useToast()
  const [batch, setBatch] = useState<Batch | null>(null)
  const [missing, setMissing] = useState(false)
  const [events, setEvents] = useState<BatchEvent[]>([])
  const [live, setLive] = useState(false)
  const [confirm, setConfirm] = useState(false)
  const [committing, setCommitting] = useState(false)
  const refetchTimer = useRef<number | undefined>(undefined)

  const load = useCallback(async () => {
    try { setBatch(await api<Batch>(`/api/apps/${code}/batches/${batchId}`)) }
    catch (e) { if (e instanceof ApiError && (e.status === 404 || e.status === 422)) setMissing(true) }
  }, [code, batchId])

  useEffect(() => { load() }, [load])

  // Live progress over SSE. Each event updates the header instantly; counts are re-read shortly after.
  useEffect(() => {
    const ctrl = new AbortController()
    setEvents([])
    streamEvents<BatchEvent>(`/api/apps/${code}/batches/${batchId}/events`, (ev) => {
      setLive(true)
      setEvents((all) => (all.some((x) => x.event_id === ev.event_id) ? all : [...all, ev]))
      setBatch((b) => b && { ...b, status: ev.status, progress_pct: ev.progress_pct, progress_message: ev.message })
      window.clearTimeout(refetchTimer.current)
      refetchTimer.current = window.setTimeout(load, 400)
    }, ctrl.signal).catch(() => setLive(false))
    return () => { ctrl.abort(); setLive(false); window.clearTimeout(refetchTimer.current) }
  }, [code, batchId, load])

  async function commit() {
    setCommitting(true)
    try {
      const r = await api<{ accepted: number; rejected: number }>(`/api/apps/${code}/batches/${batchId}/commit`, { method: 'POST' })
      toast({ tone: 'success', title: 'Batch committed', description: `${r.accepted} records loaded, ${r.rejected} rejected.` })
      setConfirm(false)
      load()
    } catch (e) {
      toast({ tone: 'error', title: 'Commit refused', description: e instanceof ApiError && typeof e.detail === 'string' ? e.detail : 'Please try again.' })
    } finally {
      setCommitting(false)
    }
  }

  if (missing) {
    return <EmptyState icon={FileSearch} title="Batch not found"
                       action={<Link to={`${app.route}/datasets`}><Button>Back to datasets</Button></Link>} />
  }
  if (!batch) return <DetailSkeleton />

  const canCommit = can('batch.commit') && batch.status === 'READY_TO_COMMIT'

  return (
    <>
      <Link to={`${app.route}/datasets`} className="mb-4 inline-flex items-center gap-1.5 text-sm text-fg-muted transition-colors hover:text-fg">
        <ArrowLeft className="size-4" /> Datasets
      </Link>

      <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2.5">
            <span className="font-mono text-xs text-fg-muted">{batch.batch_code}</span>
            <StatusBadge status={batch.status} />
            {live && !['COMMITTED', 'FAILED'].includes(batch.status) && (
              <span className="inline-flex items-center gap-1 text-xs text-fg-muted"><Radio className="size-3 animate-pulse" /> Live</span>
            )}
          </div>
          <h1 className="mt-2 truncate text-xl font-semibold tracking-tight sm:text-2xl">{batch.file_name}</h1>
        </div>
        <div className="flex shrink-0 gap-2">
          {can('mapping.review') && ['MAPPING_REVIEW', 'NEEDS_REVIEW'].includes(batch.status) && (
            <Link to={`${app.route}/mapping/${batch.batch_id}`}>
              <Button variant={batch.status === 'MAPPING_REVIEW' ? 'primary' : 'secondary'} icon={GitCompare}>Review mapping</Button>
            </Link>
          )}
          {can('data_quality.review') && batch.status === 'NEEDS_REVIEW' && (
            <Link to={`${app.route}/data-quality/${batch.batch_id}`}><Button variant="primary" icon={BadgeCheck}>Resolve issues</Button></Link>
          )}
          {canCommit && <Button variant="primary" icon={CheckCheck} onClick={() => setConfirm(true)}>Commit batch</Button>}
        </div>
      </div>

      <Card className="p-5 sm:p-6">
        <Stepper status={batch.status} events={events} />
        <div className="mt-6 flex items-center gap-3">
          <ProgressBar value={batch.status === 'COMMITTED' ? 100 : batch.progress_pct} />
          <span className="w-10 text-right text-xs text-fg-muted tabular">{batch.status === 'COMMITTED' ? 100 : batch.progress_pct}%</span>
        </div>
        <AnimatePresence mode="wait">
          <motion.p key={batch.progress_message ?? ''} initial={{ opacity: 0, y: 4 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
                    className="mt-2 min-h-5 text-sm text-fg-muted">
            {batch.progress_message}
          </motion.p>
        </AnimatePresence>
        {batch.status === 'FAILED' && batch.error_message && (
          <div className="mt-3 flex items-start gap-2 rounded-lg border border-danger/25 bg-danger/5 px-3 py-2.5 text-sm text-danger">
            <AlertTriangle className="mt-0.5 size-4 shrink-0" /> {batch.error_message}
          </div>
        )}
        {batch.status === 'READY_TO_COMMIT' && !can('batch.commit') && (
          <p className="mt-3 text-sm text-fg-muted">Ready for a reviewer to commit.</p>
        )}
      </Card>

      <div className="mt-6 grid gap-6 lg:grid-cols-[1fr_340px]">
        <div className="space-y-6">
          <Counts batch={batch} />
          <Timeline events={events} />
        </div>
        <Details batch={batch} />
      </div>

      <Dialog open={confirm} onClose={() => !committing && setConfirm(false)} title="Commit this batch?"
              description="Accepted records are loaded into the reporting tables in one transaction. This can't be undone from here."
              footer={<>
                <Button variant="ghost" onClick={() => setConfirm(false)} disabled={committing}>Cancel</Button>
                <Button variant="primary" onClick={commit} loading={committing} data-autofocus>Commit</Button>
              </>}>
        <dl className="grid grid-cols-3 gap-3 text-center">
          {(['received', 'accepted', 'rejected'] as const).map((k) => (
            <div key={k} className="rounded-lg border border-border p-3">
              <dt className="text-xs text-fg-muted capitalize">{k}</dt>
              <dd className="mt-1 text-lg font-semibold tabular">{batch.counts[k]}</dd>
            </div>
          ))}
        </dl>
      </Dialog>
    </>
  )
}

/** Happy-path steps; the current one pulses, a failure/review marks where it stopped. */
function Stepper({ status, events }: { status: BatchStatus; events: BatchEvent[] }) {
  const stoppedAt = useMemo(() => {
    if (status !== 'FAILED' && status !== 'NEEDS_REVIEW') return null
    const last = [...events].reverse().find((e) => STATUS_FLOW.includes(e.status))
    return last ? STATUS_FLOW.indexOf(last.status) : 0
  }, [status, events])
  const current = stoppedAt ?? STATUS_FLOW.indexOf(status)
  const bad = status === 'FAILED'

  return (
    <ol className="flex flex-col gap-3 sm:flex-row sm:items-center sm:gap-0">
      {STATUS_FLOW.map((s, i) => {
        const done = i < current || status === 'COMMITTED'
        const here = i === current && status !== 'COMMITTED'
        return (
          <li key={s} className="flex items-center gap-3 sm:flex-1 sm:flex-col sm:gap-2 sm:text-center">
            <div className="flex items-center sm:w-full">
              <div className={clsx('hidden h-px flex-1 sm:block', i === 0 ? 'opacity-0' : done || here ? 'bg-fg' : 'bg-border')} />
              <motion.span initial={false}
                animate={{ scale: here ? 1.08 : 1 }}
                className={clsx('relative flex size-7 shrink-0 items-center justify-center rounded-full border text-xs font-medium transition-colors duration-300',
                  done && 'border-fg bg-fg text-bg',
                  here && !stoppedAt && 'border-fg bg-surface text-fg',
                  here && stoppedAt !== null && (bad ? 'border-danger bg-danger/5 text-danger' : 'border-warning bg-warning/5 text-warning'),
                  !done && !here && 'border-border bg-surface text-fg-subtle')}>
                {here && stoppedAt === null && <span className="absolute inset-0 animate-ping rounded-full border border-fg opacity-30" />}
                {done ? <Check className="size-3.5" strokeWidth={2.5} /> : here && stoppedAt !== null ? '!' : i + 1}
              </motion.span>
              <div className={clsx('hidden h-px flex-1 sm:block', i === STATUS_FLOW.length - 1 ? 'opacity-0' : done ? 'bg-fg' : 'bg-border')} />
            </div>
            <span className={clsx('text-xs', done || here ? 'font-medium text-fg' : 'text-fg-muted')}>
              {here && stoppedAt !== null ? STATUS_LABEL[status] : STATUS_LABEL[s]}
            </span>
          </li>
        )
      })}
    </ol>
  )
}

function Counts({ batch }: { batch: Batch }) {
  const c = batch.counts
  const parts = [
    { key: 'accepted', label: 'Accepted', value: c.accepted, tone: 'bg-fg' },
    { key: 'rejected', label: 'Rejected', value: c.rejected, tone: 'bg-danger' },
    { key: 'needs_review', label: 'Needs review', value: c.needs_review, tone: 'bg-warning' },
    { key: 'pending', label: 'Pending', value: c.pending, tone: 'bg-border-strong' },
  ]
  return (
    <Card className="p-5 sm:p-6">
      <div className="flex items-baseline justify-between">
        <h2 className="text-sm font-semibold">Records</h2>
        <p className="text-sm text-fg-muted"><span className="font-semibold text-fg tabular">{c.received}</span> received</p>
      </div>
      <div className="mt-4 flex h-2 overflow-hidden rounded-full bg-muted">
        {c.received > 0 && parts.map((p) => (
          <motion.div key={p.key} className={p.tone} initial={{ width: 0 }}
                      animate={{ width: `${(p.value / c.received) * 100}%` }} transition={{ type: 'spring', stiffness: 100, damping: 22 }} />
        ))}
      </div>
      <dl className="mt-4 grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-4 lg:grid-cols-2 xl:grid-cols-4">
        {parts.map((p) => (
          <div key={p.key}>
            <dt className="flex items-center gap-1.5 text-xs text-fg-muted"><span className={clsx('size-2 shrink-0 rounded-full', p.tone)} />{p.label}</dt>
            <dd className="mt-1 text-lg font-semibold tabular">{p.value}</dd>
          </div>
        ))}
      </dl>
      {c.received === 0 && <p className="mt-2 text-xs text-fg-muted">Records appear once extraction writes them.</p>}
    </Card>
  )
}

function Timeline({ events }: { events: BatchEvent[] }) {
  const items = [...events].reverse()
  return (
    <Card className="p-5 sm:p-6">
      <h2 className="text-sm font-semibold">Activity</h2>
      {items.length === 0 ? <p className="mt-3 text-sm text-fg-muted">Waiting for events…</p> : (
        <ol className="mt-4 space-y-0">
          <AnimatePresence initial={false}>
            {items.map((e, i) => (
              <motion.li key={e.event_id} layout initial={{ opacity: 0, y: -6 }} animate={{ opacity: 1, y: 0 }}
                         className="relative flex gap-4 pb-5 last:pb-0">
                {i < items.length - 1 && <span className="absolute top-3 left-[5px] h-full w-px bg-border" />}
                <span className={clsx('relative mt-1.5 size-[11px] shrink-0 rounded-full border-2 border-bg',
                  i === 0 ? 'bg-fg' : 'bg-border-strong')} />
                <div className="min-w-0 flex-1">
                  <p className="text-sm">
                    <span className="font-medium">{STATUS_LABEL[e.status]}</span>
                    {e.progress_pct > 0 && e.progress_pct < 100 && <span className="text-fg-muted"> · {e.progress_pct}%</span>}
                  </p>
                  {e.message && <p className="truncate text-sm text-fg-muted">{e.message}</p>}
                </div>
                <time className="shrink-0 text-xs text-fg-subtle tabular">
                  {new Date(e.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}
                </time>
              </motion.li>
            ))}
          </AnimatePresence>
        </ol>
      )}
    </Card>
  )
}

function Details({ batch }: { batch: Batch }) {
  const [copied, setCopied] = useState(false)
  const rows: [string, React.ReactNode][] = [
    ['File type', batch.file_type],
    ['Size', fmtBytes(batch.file_size_bytes)],
    ['Source system', batch.source_system || '—'],
    ['Period', batch.period_start ? `${fmtDate(batch.period_start)} – ${fmtDate(batch.period_end)}` : '—'],
    ['Uploaded', fmtDateTime(batch.uploaded_at)],
    ['Committed', fmtDateTime(batch.committed_at)],
  ]
  return (
    <Card className="h-fit p-5 sm:p-6">
      <h2 className="text-sm font-semibold">Details</h2>
      <dl className="mt-4 space-y-3 text-sm">
        {rows.map(([k, v]) => (
          <div key={k} className="flex justify-between gap-4">
            <dt className="text-fg-muted">{k}</dt><dd className="text-right">{v}</dd>
          </div>
        ))}
        <div className="border-t border-border pt-3">
          <dt className="text-fg-muted">SHA-256</dt>
          <dd className="mt-1 flex items-center gap-2">
            <code className="min-w-0 flex-1 truncate font-mono text-xs">{batch.sha256}</code>
            <button onClick={() => { navigator.clipboard.writeText(batch.sha256); setCopied(true); setTimeout(() => setCopied(false), 1500) }}
                    aria-label="Copy checksum" className="rounded-md p-1.5 text-fg-muted transition-colors hover:bg-muted hover:text-fg">
              {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
            </button>
          </dd>
        </div>
      </dl>
    </Card>
  )
}

function DetailSkeleton() {
  return (
    <div className="space-y-6">
      <Skeleton className="h-4 w-20" />
      <div className="space-y-2"><Skeleton className="h-4 w-40" /><Skeleton className="h-7 w-72" /></div>
      <Skeleton className="h-36 rounded-xl" />
      <div className="grid gap-6 lg:grid-cols-[1fr_340px]"><Skeleton className="h-64 rounded-xl" /><Skeleton className="h-64 rounded-xl" /></div>
    </div>
  )
}
