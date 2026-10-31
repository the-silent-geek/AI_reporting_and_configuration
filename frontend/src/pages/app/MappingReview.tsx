import clsx from 'clsx'
import { ArrowLeft, ArrowRight, CheckCircle2, GitCompare, Sparkles } from 'lucide-react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { Button } from '../../components/ui/Button'
import { inputClass } from '../../components/ui/Field'
import { Badge, Card, EmptyState, PageHeader, Skeleton, StatusBadge } from '../../components/ui/Misc'
import { useToast } from '../../components/ui/Toast'
import { ApiError, api, json } from '../../lib/api'
import { useApp } from '../../lib/appContext'
import { fmtRelative } from '../../lib/format'
import type { BatchStatus } from '../../lib/types'

/* Mapping review: the AI worker proposed what each uploaded field means; a person
   confirms or changes it, then the database applies it and validates every record. */

interface Column { column: string; type: string; required: boolean; key: boolean }
interface Transform { type: string; format?: string; value?: string; remove_characters?: string[]; true_values?: string[] }
interface Suggestion {
  source_field: string | null; target_field: string | null; target_entity?: string | null; transform?: Transform
  confidence?: number; rationale?: string; method?: string; needs_review?: boolean
}
interface MappingData {
  batch: { batch_id: string; batch_code: string; file_name: string; status: BatchStatus }
  mapping: { version: number; status: string; mappings: Suggestion[]; proposed_by_ai: boolean } | null
  suggested_entity: string | null
  entities: Record<string, Column[]>
  fields: { source_field: string; samples: string[] }[]
  records: number
}
export interface QueueItem {
  batch_id: string; batch_code: string; file_name: string; status: BatchStatus; uploaded_at: string
  records?: number; suggested_entity?: string | null; open_issues?: number; needs_review?: number; accepted?: number
}

const TRANSFORMS: { value: string; label: string }[] = [
  { value: 'trim', label: 'Text' }, { value: 'uppercase', label: 'Text, upper-case' },
  { value: 'parse_decimal', label: 'Number (decimal)' }, { value: 'parse_integer', label: 'Whole number' },
  { value: 'parse_date', label: 'Date' }, { value: 'parse_datetime', label: 'Date and time' },
  { value: 'parse_boolean', label: 'Yes / No' }, { value: 'none', label: 'As is' },
]
const pretty = (s: string) => s.replace(/_/g, ' ')

/** Default transform for a column type when the user picks a different target. */
function transformFor(type: string): Transform {
  if (/numeric|double|real/.test(type)) return { type: 'parse_decimal', remove_characters: [','] }
  if (/int/.test(type)) return { type: 'parse_integer' }
  if (type === 'date') return { type: 'parse_date' }
  if (/timestamp/.test(type)) return { type: 'parse_datetime' }
  if (type === 'boolean') return { type: 'parse_boolean' }
  if (/character\(3\)/.test(type)) return { type: 'uppercase' }
  return { type: 'trim' }
}

export function errorText(e: unknown) {
  return e instanceof ApiError && typeof e.detail === 'string' ? e.detail : 'Please try again.'
}

export function useReviewQueue() {
  const { code } = useApp()
  const [queue, setQueue] = useState<{ mapping: QueueItem[]; quality: QueueItem[] } | null>(null)
  const load = useCallback(async () => {
    try { setQueue(await api(`/api/apps/${code}/review/queue`)) } catch { setQueue({ mapping: [], quality: [] }) }
  }, [code])
  useEffect(() => { load() }, [load])
  return queue
}

export function QueueTable({ items, to, extra }: { items: QueueItem[]; to: (b: QueueItem) => string; extra: (b: QueueItem) => string }) {
  const navigate = useNavigate()
  return (
    <ul className="divide-y divide-border">
      {items.map((b) => (
        <li key={b.batch_id}>
          <button onClick={() => navigate(to(b))}
                  className="flex w-full items-center gap-4 px-5 py-3.5 text-left transition-colors hover:bg-subtle">
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium">{b.file_name}</p>
              <p className="text-xs text-fg-muted"><span className="font-mono">{b.batch_code}</span> · {extra(b)} · {fmtRelative(b.uploaded_at)}</p>
            </div>
            <StatusBadge status={b.status} />
            <ArrowRight className="size-4 text-fg-subtle" />
          </button>
        </li>
      ))}
    </ul>
  )
}

export function MappingQueue() {
  const { app } = useApp()
  const queue = useReviewQueue()
  return (
    <>
      <PageHeader title="Mapping review" description="Confirm what each uploaded field means before the data is validated." />
      <Card className="overflow-hidden">
        {!queue ? <div className="space-y-3 p-5">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-10" />)}</div>
          : queue.mapping.length ? (
            <QueueTable items={queue.mapping} to={(b) => `${app.route}/mapping/${b.batch_id}`}
                        extra={(b) => `${b.records} records${b.suggested_entity ? ` · AI suggests ${pretty(b.suggested_entity)}` : ''}`} />
          ) : (
            <EmptyState icon={GitCompare} title="Nothing to map"
                        action={<Link to={`${app.route}/datasets`}><Button>Go to datasets</Button></Link>}>
              Uploaded files appear here once the AI worker has suggested their field mappings.
            </EmptyState>
          )}
      </Card>
    </>
  )
}

interface Row { source_field: string; samples: string[]; target: string; transform: Transform; ai?: Suggestion }

export function MappingEditor() {
  const { batchId = '' } = useParams()
  const { app, code } = useApp()
  const toast = useToast()
  const navigate = useNavigate()
  const [data, setData] = useState<MappingData | null>(null)
  const [entity, setEntity] = useState('')
  const [rows, setRows] = useState<Row[]>([])
  const [constants, setConstants] = useState<Record<string, string>>({})
  const [saving, setSaving] = useState(false)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    api<MappingData>(`/api/apps/${code}/batches/${batchId}/mapping`).then((d) => {
      setData(d)
      const items = d.mapping?.mappings ?? []
      const ent = items.find((m) => m.target_entity)?.target_entity ?? d.suggested_entity ?? Object.keys(d.entities)[0] ?? ''
      setEntity(ent)
      setRows(d.fields.map((f) => {
        const ai = items.find((m) => m.source_field === f.source_field)
        return { source_field: f.source_field, samples: f.samples, target: ai?.target_field ?? '',
                 transform: ai?.transform && ai.transform.type !== 'none' ? ai.transform : { type: 'trim' }, ai }
      }))
      setConstants(Object.fromEntries(items.filter((m) => m.transform?.type === 'constant' && m.target_field)
        .map((m) => [m.target_field!, String(m.transform!.value ?? '')])))
    }).catch(() => setFailed(true))
  }, [code, batchId])

  const columns = useMemo(() => data?.entities[entity] ?? [], [data, entity])
  const used = rows.filter((r) => r.target).map((r) => r.target)
  const duplicates = [...new Set(used.filter((t, i) => used.indexOf(t) !== i))]
  const unmappedRequired = columns.filter((c) => c.required && !used.includes(c.column))
  const missing = unmappedRequired.filter((c) => !constants[c.column]?.trim())

  function changeEntity(e: string) {
    setEntity(e)
    const cols = new Set((data?.entities[e] ?? []).map((c) => c.column))
    setRows((rs) => rs.map((r) => (cols.has(r.target) ? r : { ...r, target: '' })))
    setConstants({})
  }
  function setTarget(i: number, target: string) {
    const col = columns.find((c) => c.column === target)
    setRows((rs) => rs.map((r, j) => (j === i ? { ...r, target, transform: col ? transformFor(col.type) : r.transform } : r)))
  }
  function setTransform(i: number, t: Transform) { setRows((rs) => rs.map((r, j) => (j === i ? { ...r, transform: t } : r))) }

  async function approve() {
    setSaving(true)
    const mappings = [
      ...rows.filter((r) => r.target).map((r) => ({ source_field: r.source_field, target_field: r.target, transform: r.transform })),
      ...unmappedRequired.map((c) => ({ source_field: null, target_field: c.column,
                                        transform: { type: 'constant', value: constants[c.column]!.trim() } })),
    ]
    try {
      const r = await api<{ status: BatchStatus; accepted: number; needs_review: number }>(
        `/api/apps/${code}/batches/${batchId}/mapping/approve`, { method: 'POST', ...json({ target_entity: entity, mappings }) })
      if (r.status === 'READY_TO_COMMIT') {
        toast({ tone: 'success', title: 'Mapping approved', description: `All ${r.accepted} records passed validation.` })
        navigate(`${app.route}/datasets/${batchId}`)
      } else {
        toast({ tone: 'info', title: 'Mapping approved', description: `${r.needs_review} record(s) need attention in Data quality.` })
        navigate(`${app.route}/data-quality/${batchId}`)
      }
    } catch (e) {
      toast({ tone: 'error', title: 'Mapping not approved', description: errorText(e) })
    } finally {
      setSaving(false)
    }
  }

  if (failed) return <EmptyState icon={GitCompare} title="Mapping not available"
                                 action={<Link to={`${app.route}/mapping`}><Button>Back</Button></Link>}>You may not have access to this batch.</EmptyState>
  if (!data) return <div className="space-y-3">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-14" />)}</div>

  const reapprove = data.mapping?.status === 'APPROVED'
  return (
    <>
      <Link to={`${app.route}/mapping`} className="mb-4 inline-flex items-center gap-1.5 text-sm text-fg-muted transition-colors hover:text-fg">
        <ArrowLeft className="size-4" /> Mapping review
      </Link>
      <PageHeader title={data.batch.file_name}
                  description={<><span className="font-mono">{data.batch.batch_code}</span> · {data.records} records</>}
                  actions={<StatusBadge status={data.batch.status} />} />

      <Card className="mb-4 flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between sm:p-5">
        <div>
          <p className="text-sm font-medium">Target table</p>
          <p className="text-xs text-fg-muted">Which kind of record each row of this file is.</p>
        </div>
        <select value={entity} onChange={(e) => changeEntity(e.target.value)} aria-label="Target table"
                className={clsx(inputClass, 'sm:w-64')}>
          {Object.keys(data.entities).map((e) => <option key={e} value={e}>{pretty(e)}</option>)}
        </select>
      </Card>

      <Card className="overflow-x-auto">
        <table className="w-full min-w-[760px] text-left text-sm">
          <thead className="border-b border-border bg-subtle text-xs text-fg-muted">
            <tr>
              <th className="px-4 py-2.5 font-medium">Uploaded field</th>
              <th className="px-4 py-2.5 font-medium">Sample values</th>
              <th className="px-4 py-2.5 font-medium">Maps to</th>
              <th className="px-4 py-2.5 font-medium">Convert as</th>
              <th className="px-4 py-2.5 font-medium">AI suggestion</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {rows.map((r, i) => (
              <tr key={r.source_field} className={clsx(r.target && duplicates.includes(r.target) && 'bg-danger/5')}>
                <td className="px-4 py-3 font-medium">{r.source_field}</td>
                <td className="max-w-[220px] px-4 py-3 text-xs text-fg-muted">
                  <span className="line-clamp-2">{r.samples.join(' · ') || '–'}</span>
                </td>
                <td className="px-4 py-3">
                  <select value={r.target} onChange={(e) => setTarget(i, e.target.value)} aria-label={`Target for ${r.source_field}`}
                          className={clsx(inputClass, 'h-9 min-w-44')}>
                    <option value="">Don't import</option>
                    {columns.map((c) => <option key={c.column} value={c.column}>{pretty(c.column)}{c.required ? ' *' : ''}</option>)}
                  </select>
                </td>
                <td className="px-4 py-3">
                  {r.target ? (
                    <div className="flex gap-2">
                      <select value={r.transform.type} onChange={(e) => setTransform(i, { type: e.target.value })}
                              aria-label={`Conversion for ${r.source_field}`} className={clsx(inputClass, 'h-9 min-w-36')}>
                        {TRANSFORMS.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
                      </select>
                      {(r.transform.type === 'parse_date' || r.transform.type === 'parse_datetime') && (
                        <input value={r.transform.format ?? ''} placeholder="auto (ISO)" title="Date format, e.g. %d-%b-%Y"
                               onChange={(e) => setTransform(i, { ...r.transform, format: e.target.value || undefined })}
                               className={clsx(inputClass, 'h-9 w-28 font-mono text-xs')} />
                      )}
                    </div>
                  ) : <span className="text-xs text-fg-subtle">–</span>}
                </td>
                <td className="px-4 py-3">
                  {r.ai?.target_field ? (
                    <span title={r.ai.rationale} className="inline-flex items-center gap-1.5 text-xs text-fg-muted">
                      <Sparkles className="size-3.5" />
                      {pretty(r.ai.target_field)}
                      {r.ai.confidence !== undefined && <span className="tabular">{Math.round(r.ai.confidence * 100)}%</span>}
                      {r.ai.method && <Badge>{r.ai.method}</Badge>}
                      {r.ai.needs_review && <span className="size-1.5 rounded-full bg-warning" aria-label="check this one" />}
                    </span>
                  ) : <span className="text-xs text-fg-subtle" title={r.ai?.rationale}>No suggestion</span>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>

      {unmappedRequired.length > 0 && (
        <Card className="mt-4 p-4 sm:p-5">
          <p className="text-sm font-medium">Required fields not in this file</p>
          <p className="mb-3 text-xs text-fg-muted">Map an uploaded field to them, or give one value for every record.</p>
          <div className="grid gap-3 sm:grid-cols-2">
            {unmappedRequired.map((c) => (
              <label key={c.column} className="block">
                <span className="mb-1 block text-xs font-medium">{pretty(c.column)} <span className="text-fg-subtle">({c.type})</span></span>
                <input value={constants[c.column] ?? ''} onChange={(e) => setConstants((k) => ({ ...k, [c.column]: e.target.value }))}
                       placeholder={c.type.startsWith('character(3)') ? 'e.g. USD' : 'Value for every record'} className={inputClass} />
              </label>
            ))}
          </div>
        </Card>
      )}

      <div className="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:items-center sm:justify-between">
        <p className={clsx('text-sm', missing.length || duplicates.length ? 'text-danger' : 'text-fg-muted')}>
          {duplicates.length ? `Two fields map to ${duplicates.map(pretty).join(', ')}.`
            : missing.length ? `Still needed: ${missing.map((c) => pretty(c.column)).join(', ')}.`
            : reapprove ? 'Approving again re-applies the mapping and discards earlier corrections.'
            : <span className="inline-flex items-center gap-1.5"><CheckCircle2 className="size-4" /> Every required field is covered.</span>}
        </p>
        <Button variant="primary" onClick={approve} loading={saving} disabled={!!missing.length || !!duplicates.length || !entity}>
          Approve and validate
        </Button>
      </div>
    </>
  )
}
