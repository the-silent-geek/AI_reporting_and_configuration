import clsx from 'clsx'
import { ArrowLeft, BadgeCheck, Check, CheckCheck, ChevronDown, RefreshCw, X } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Button } from '../../components/ui/Button'
import { Dialog } from '../../components/ui/Dialog'
import { inputClass } from '../../components/ui/Field'
import { Badge, Card, EmptyState, PageHeader, Skeleton, StatusBadge } from '../../components/ui/Misc'
import { useToast } from '../../components/ui/Toast'
import { api, json } from '../../lib/api'
import { useApp } from '../../lib/appContext'
import type { BatchStatus } from '../../lib/types'
import { QueueTable, errorText, useReviewQueue } from './MappingReview'

/* Data quality: validation found problems; fix values, confirm extraction warnings
   or reject records. Every action re-validates the batch; with no open issues it
   becomes Ready to commit. The original value is always kept next to the fix. */

interface Issue {
  issue_id: number; record_no: number | null; field: string | null; rule_code: string; severity: 'ERROR' | 'WARNING'
  message: string; original_value: string | null; corrected_value: string | null; resolved_at: string | null
  record_state: string | null; current_value: unknown; source_location: Record<string, unknown> | null
  raw_fields: Record<string, unknown> | null
}
interface IssueData {
  batch: { batch_id: string; batch_code: string; file_name: string; status: BatchStatus }
  counts: { records: number; accepted: number; needs_review: number; rejected: number; pending: number }
  entity: string | null
  columns: { column: string; type: string; required: boolean }[]
  issues: Issue[]
}
interface ActionResult { status: BatchStatus }

const RULE_LABEL: Record<string, string> = {
  CONVERSION: 'Could not convert', REQUIRED: 'Missing value', TYPE: 'Wrong type', CHECK: 'Rule not met',
  REFERENCE: 'Unknown reference', DUPLICATE: 'Duplicate', EXTRACTION_LOW_CONFIDENCE: 'Low OCR confidence',
  EXTRACTION_RAGGED_ROW: 'Row shape',
}
const pretty = (s: string) => s.replace(/_/g, ' ')
const where = (loc: Record<string, unknown> | null) =>
  !loc ? '' : loc.page ? `page ${loc.page}${loc.row ? `, row ${loc.row}` : ''}` : loc.sheet ? `${loc.sheet} row ${loc.row}`
    : loc.row ? `row ${loc.row}` : loc.index !== undefined ? `item ${Number(loc.index) + 1}` : ''

export function QualityQueue() {
  const { app } = useApp()
  const queue = useReviewQueue()
  return (
    <>
      <PageHeader title="Data quality" description="Resolve validation issues so batches can be committed." />
      <Card className="overflow-hidden">
        {!queue ? <div className="space-y-3 p-5">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-10" />)}</div>
          : queue.quality.length ? (
            <QueueTable items={queue.quality} to={(b) => `${app.route}/data-quality/${b.batch_id}`}
                        extra={(b) => b.open_issues ? `${b.open_issues} open issue(s)` : `${b.accepted} records accepted`} />
          ) : (
            <EmptyState icon={BadgeCheck} title="No issues to resolve"
                        action={<Link to={`${app.route}/mapping`}><Button>Go to mapping review</Button></Link>}>
              Batches appear here after their mapping is approved.
            </EmptyState>
          )}
      </Card>
    </>
  )
}

export function QualityDetail() {
  const { batchId = '' } = useParams()
  const { app, code, can } = useApp()
  const toast = useToast()
  const [data, setData] = useState<IssueData | null>(null)
  const [failed, setFailed] = useState(false)
  const [busy, setBusy] = useState<string | null>(null)
  const [rejecting, setRejecting] = useState<number | null>(null)
  const [reason, setReason] = useState('')
  const [showResolved, setShowResolved] = useState(false)
  const editable = can('data_quality.review') && !!data && ['NEEDS_REVIEW', 'READY_TO_COMMIT'].includes(data.batch.status)

  const load = useCallback(async () => {
    try { setData(await api<IssueData>(`/api/apps/${code}/batches/${batchId}/issues`)) } catch { setFailed(true) }
  }, [code, batchId])
  useEffect(() => { load() }, [load])

  async function act(key: string, path: string, body?: unknown, done?: string) {
    setBusy(key)
    try {
      const r = await api<ActionResult>(`/api/apps/${code}/batches/${batchId}/${path}`, { method: 'POST', ...(body ? json(body) : {}) })
      toast(r.status === 'READY_TO_COMMIT'
        ? { tone: 'success', title: 'Ready to commit', description: 'Every remaining record passed validation.' }
        : { tone: 'info', title: done ?? 'Saved' })
      await load()
      return true
    } catch (e) {
      toast({ tone: 'error', title: 'Not saved', description: errorText(e) })
      return false
    } finally {
      setBusy(null)
    }
  }

  const { open, resolved } = useMemo(() => {
    const issues = data?.issues ?? []
    const byRecord = new Map<number, Issue[]>()
    for (const i of issues.filter((x) => !x.resolved_at)) byRecord.set(i.record_no ?? 0, [...(byRecord.get(i.record_no ?? 0) ?? []), i])
    return { open: [...byRecord.entries()], resolved: issues.filter((x) => x.resolved_at) }
  }, [data])

  if (failed) return <EmptyState icon={BadgeCheck} title="Batch not available"
                                 action={<Link to={`${app.route}/data-quality`}><Button>Back</Button></Link>} />
  if (!data) return <div className="space-y-3">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-24" />)}</div>

  const c = data.counts
  return (
    <>
      <Link to={`${app.route}/data-quality`} className="mb-4 inline-flex items-center gap-1.5 text-sm text-fg-muted transition-colors hover:text-fg">
        <ArrowLeft className="size-4" /> Data quality
      </Link>
      <PageHeader title={data.batch.file_name}
                  description={<><span className="font-mono">{data.batch.batch_code}</span>{data.entity && <> · {pretty(data.entity)} records</>}</>}
                  actions={<>
                    <StatusBadge status={data.batch.status} />
                    {editable && <Button icon={RefreshCw} loading={busy === 'validate'}
                                         onClick={() => act('validate', 'validate', undefined, 'Validated again')}>Re-validate</Button>}
                    {data.batch.status === 'READY_TO_COMMIT' && (
                      <Link to={`${app.route}/datasets/${batchId}`}><Button variant="primary" icon={CheckCheck}>Go to commit</Button></Link>
                    )}
                  </>} />

      <div className="mb-6 grid grid-cols-2 gap-3 sm:grid-cols-4">
        {([['Records', c.records], ['Accepted', c.accepted], ['Need review', c.needs_review], ['Rejected', c.rejected]] as const)
          .map(([label, value]) => (
            <Card key={label} className="p-4">
              <p className="text-xs text-fg-muted">{label}</p>
              <p className="mt-1 text-2xl font-semibold tabular">{value}</p>
            </Card>
          ))}
      </div>

      {open.length === 0 ? (
        <Card><EmptyState icon={BadgeCheck} title="No open issues">
          {data.batch.status === 'READY_TO_COMMIT' ? 'This batch is ready for a reviewer to commit.' : 'Nothing left to fix here.'}
        </EmptyState></Card>
      ) : (
        <div className="space-y-3">
          {open.map(([recordNo, issues]) => (
            <RecordIssues key={recordNo} recordNo={recordNo} issues={issues} columns={data.columns} editable={editable} busy={busy}
                          onCorrect={(field, value) => act(`fix-${recordNo}-${field}`, `records/${recordNo}/correct`, { field, value }, 'Value corrected')}
                          onConfirm={(id) => act(`confirm-${id}`, `issues/${id}/confirm`, undefined, 'Confirmed')}
                          onReject={() => { setRejecting(recordNo); setReason('') }} />
          ))}
        </div>
      )}

      {resolved.length > 0 && (
        <Card className="mt-6">
          <button onClick={() => setShowResolved((s) => !s)} aria-expanded={showResolved}
                  className="flex w-full items-center justify-between px-5 py-3.5 text-sm font-medium">
            Resolved ({resolved.length})
            <ChevronDown className={clsx('size-4 text-fg-muted transition-transform', showResolved && 'rotate-180')} />
          </button>
          {showResolved && (
            <ul className="divide-y divide-border border-t border-border text-sm">
              {resolved.map((i) => (
                <li key={i.issue_id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-5 py-2.5">
                  <span className="text-xs text-fg-muted">Record {i.record_no}</span>
                  <Badge>{RULE_LABEL[i.rule_code] ?? pretty(i.rule_code)}</Badge>
                  {i.field && <span className="font-medium">{pretty(i.field)}</span>}
                  <span className="text-fg-muted">{i.original_value ?? '–'} → {i.corrected_value}</span>
                </li>
              ))}
            </ul>
          )}
        </Card>
      )}

      <Dialog open={rejecting !== null} onClose={() => setRejecting(null)} title={`Reject record ${rejecting}?`}
              description="It won't be loaded at commit and is counted as rejected. The reason is kept in the audit trail."
              footer={<>
                <Button variant="ghost" onClick={() => setRejecting(null)}>Cancel</Button>
                <Button variant="danger" disabled={!reason.trim()} loading={busy === `reject-${rejecting}`}
                        onClick={async () => { if (await act(`reject-${rejecting}`, `records/${rejecting}/reject`, { reason }, 'Record rejected')) setRejecting(null) }}>
                  Reject record
                </Button>
              </>}>
        <textarea value={reason} onChange={(e) => setReason(e.target.value)} rows={3} maxLength={500} data-autofocus
                  placeholder="Why is this record excluded?" aria-label="Reason" className={clsx(inputClass, 'h-auto py-2')} />
      </Dialog>
    </>
  )
}

function RecordIssues({ recordNo, issues, columns, editable, busy, onCorrect, onConfirm, onReject }: {
  recordNo: number; issues: Issue[]; columns: IssueData['columns']; editable: boolean; busy: string | null
  onCorrect: (field: string, value: string) => void; onConfirm: (id: number) => void; onReject: () => void
}) {
  const [showRaw, setShowRaw] = useState(false)
  const first = issues[0]!
  return (
    <Card className="p-4 sm:p-5">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2 text-sm">
          <span className="font-semibold">Record {recordNo}</span>
          {where(first.source_location) && <span className="text-xs text-fg-muted">· {where(first.source_location)} of the file</span>}
        </div>
        <div className="flex gap-1.5">
          {first.raw_fields && <Button size="sm" variant="ghost" onClick={() => setShowRaw((s) => !s)}>{showRaw ? 'Hide' : 'Show'} original row</Button>}
          {editable && <Button size="sm" variant="danger" icon={X} onClick={onReject}>Reject</Button>}
        </div>
      </div>
      {showRaw && first.raw_fields && (
        <dl className="mb-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 rounded-lg bg-subtle p-3 text-xs">
          {Object.entries(first.raw_fields).map(([k, v]) => (
            <div key={k} className="contents"><dt className="text-fg-muted">{k}</dt><dd className="font-mono">{String(v ?? '')}</dd></div>
          ))}
        </dl>
      )}
      <ul className="space-y-3">
        {issues.map((i) => <IssueRow key={i.issue_id} issue={i} columns={columns} editable={editable} busy={busy}
                                     onCorrect={onCorrect} onConfirm={onConfirm} />)}
      </ul>
    </Card>
  )
}

function IssueRow({ issue: i, columns, editable, busy, onCorrect, onConfirm }: {
  issue: Issue; columns: IssueData['columns']; editable: boolean; busy: string | null
  onCorrect: (field: string, value: string) => void; onConfirm: (id: number) => void
}) {
  const [field, setField] = useState(i.field ?? '')
  const current = i.field && i.current_value !== null && i.current_value !== undefined ? String(i.current_value) : ''
  const [value, setValue] = useState(current || (i.rule_code === 'CONVERSION' ? i.original_value ?? '' : ''))
  const column = columns.find((c) => c.column === field)
  const confirmable = i.rule_code.startsWith('EXTRACTION') || i.rule_code === 'CONVERSION'
  const extraction = i.rule_code.startsWith('EXTRACTION')
  const key = `fix-${i.record_no}-${field}`

  return (
    <li className="rounded-lg border border-border p-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge className={i.severity === 'ERROR' ? 'border-danger/30 text-danger' : 'border-warning/30 text-warning'}>
          {RULE_LABEL[i.rule_code] ?? pretty(i.rule_code)}
        </Badge>
        {i.field && <span className="text-sm font-medium">{pretty(i.field)}</span>}
      </div>
      <p className="mt-1.5 text-sm text-fg-muted">{i.message}</p>
      {editable && (
        <div className="mt-3 flex flex-col gap-2 sm:flex-row">
          {!extraction && (
            <>
              {!i.field && (
                <select value={field} onChange={(e) => setField(e.target.value)} aria-label="Field to fix"
                        className={clsx(inputClass, 'h-9 sm:w-48')}>
                  <option value="">Field to fix…</option>
                  {columns.map((c) => <option key={c.column} value={c.column}>{pretty(c.column)}</option>)}
                </select>
              )}
              <input value={value} onChange={(e) => setValue(e.target.value)} disabled={!field}
                     placeholder={column ? `${column.type}${column.type === 'date' ? ', YYYY-MM-DD' : ''}` : 'Pick a field'}
                     aria-label={`Corrected ${field || 'value'}`} className={clsx(inputClass, 'h-9 flex-1')}
                     onKeyDown={(e) => e.key === 'Enter' && field && onCorrect(field, value)} />
              <Button size="sm" icon={Check} disabled={!field} loading={busy === key} onClick={() => onCorrect(field, value)}>Save fix</Button>
            </>
          )}
          {confirmable && (
            <Button size="sm" variant="ghost" loading={busy === `confirm-${i.issue_id}`} onClick={() => onConfirm(i.issue_id)}>
              {extraction ? 'Values are correct' : 'Leave empty'}
            </Button>
          )}
        </div>
      )}
    </li>
  )
}
