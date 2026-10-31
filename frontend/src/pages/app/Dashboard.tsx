import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '../../components/ui/Button'
import { Card, PageHeader } from '../../components/ui/Misc'
import { api } from '../../lib/api'
import { useApp } from '../../lib/appContext'

type Row = Record<string, unknown>
type Bucket = { label: string; currency: string; value: number; records: Row[] }
type Metric = { id: string; title: string; chart?: 'bar' | 'donut' | 'line'; amount?: string; source: string; buckets: Bucket[]; record_count: number }
type DashboardData = { metrics: Metric[]; generated_at: string }
const colors = ['#2563eb', '#0d9488', '#d97706', '#9333ea', '#dc2626', '#64748b']
const fmt = (v: unknown) => typeof v === 'number' ? v.toLocaleString(undefined, { maximumFractionDigits: 2 }) : String(v ?? '—')
const localDate = (d: Date) => [d.getFullYear(), String(d.getMonth()+1).padStart(2,'0'), String(d.getDate()).padStart(2,'0')].join('-')

export function Dashboard() {
  const { app, code } = useApp()
  const [start, setStart] = useState(() => localDate(new Date(new Date().getFullYear(), 0, 1)))
  const [end, setEnd] = useState(() => localDate(new Date()))
  const [range, setRange] = useState({ start, end })
  const [data, setData] = useState<DashboardData | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [selection, setSelection] = useState<{ title: string; records: Row[] } | null>(null)
  const [page, setPage] = useState(0)
  useEffect(() => {
    let active = true
    setLoading(true); setError(''); setData(null); setSelection(null)
    api<DashboardData>(`/api/apps/${code}/dashboard?start_date=${range.start}&end_date=${range.end}`)
      .then(d => { if(active) setData(d) })
      .catch(e => { if(active) setError(e.message) })
      .finally(() => { if(active) setLoading(false) })
    return () => { active = false }
  }, [code, range])
  function inspect(title: string, records: Row[]) { setSelection({ title, records }); setPage(0) }
  const columns = selection ? [...new Set(selection.records.flatMap(r => Object.keys(r)))] : []
  return <>
    <PageHeader title={app.name + ' dashboard'} description="Business figures from committed ingestion data. Select a card, chart point or category to inspect its records." />
    <form className="mb-5 flex flex-wrap items-end gap-3" onSubmit={e => { e.preventDefault(); if(start <= end) setRange({start,end}) }}>
      <label className="text-sm">From<input aria-label="Start date" type="date" required value={start} max={end} onChange={e=>setStart(e.target.value)} className="mt-1 block rounded border border-border bg-surface p-2" /></label>
      <label className="text-sm">To<input aria-label="End date" type="date" required value={end} min={start} onChange={e=>setEnd(e.target.value)} className="mt-1 block rounded border border-border bg-surface p-2" /></label>
      <Button type="submit" variant="primary" loading={loading}>Apply / Refresh</Button>
    </form>
    <p className="mb-5 text-xs text-fg-muted">{code === 'erp' ? 'Payables: invoices issued by the end date, less allocations and approved credits effective by that date. Overdue means due before that date. Expenditure means payments processed in the selected period.' : code === 'aml' ? 'Alerts are filtered by raised date; investigations by opened date (UTC). Open means no closed date and current status other than CLOSED, RESOLVED or CANCELLED. Status figures reflect current state, not historical state.' : 'Applications are filtered by applied date; disbursements by paid date. Approval and rejection use current application status.'} Amounts are separated by currency.</p>
    {error && <p role="alert" className="mb-4 text-danger">{error}</p>}
    {loading && <p role="status">Loading dashboard…</p>}
    {data && <>
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">{data.metrics.filter(m=>!m.chart).map(m=>
        <Card className="p-4" key={m.id}><button className="w-full text-left" onClick={()=>inspect(m.title,m.buckets.flatMap(b=>b.records))}>
          <span className="text-sm text-fg-muted">{m.title}</span>
          {m.buckets.length ? m.buckets.map(b=><p key={b.currency} className="mt-2 text-2xl font-semibold">{b.currency} {fmt(b.value)}</p>) : <p className="mt-2 text-2xl font-semibold">0</p>}
          <span className="mt-3 block text-xs text-fg-muted">Inspect {m.record_count} records →</span>
        </button></Card>)}</div>
      <div className="mt-5 grid gap-4 lg:grid-cols-2">{data.metrics.filter(m=>m.chart).map(m=>
        <Card className="p-5" key={m.id}><h2 className="mb-4 font-semibold">{m.title}</h2>
          {!m.buckets.length && <p className="text-sm text-fg-muted">No contributing records in this period.</p>}
          {[...new Set(m.buckets.map(b=>b.currency))].map(currency=><div className="mb-5" key={currency}>
            {currency && <h3 className="mb-2 text-sm font-medium">{currency}</h3>}
            <Chart metric={m} buckets={m.buckets.filter(b=>b.currency===currency)} inspect={b=>inspect(m.title+' · '+b.label+' '+b.currency,b.records)} />
          </div>)}
        </Card>)}</div>
      <p className="mt-3 text-xs text-fg-muted">Calculated {new Date(data.generated_at).toLocaleString()}. Refresh after committing new data. Empty months have zero records.</p>
    </>}
    {selection && <Card className="mt-6 p-5">
      <div className="flex items-center justify-between gap-3"><h2 className="font-semibold">{selection.title} — {selection.records.length} contributing records</h2><Button onClick={()=>setSelection(null)}>Close</Button></div>
      <p className="my-3 text-xs text-fg-muted">Batch links identify the source upload; source record numbers identify the ingested rows.</p>
      <div className="max-h-96 overflow-auto"><table className="w-full text-left text-xs"><thead><tr>{columns.map(c=><th className="whitespace-nowrap p-2" key={c}>{c.replaceAll('_',' ')}</th>)}</tr></thead>
        <tbody>{selection.records.slice(page*25,(page+1)*25).map((r,i)=><tr className="border-t border-border" key={i}>{columns.map(c=><td className="whitespace-nowrap p-2" key={c}>{c==='batch_id' ? <Link className="underline" to={app.route+'/datasets/'+r[c]}>{fmt(r[c])}</Link> : fmt(r[c])}</td>)}</tr>)}</tbody>
      </table></div>
      <div className="mt-3 flex gap-3"><Button disabled={!page} onClick={()=>setPage(p=>p-1)}>Previous</Button><span className="text-sm">Page {page+1} of {Math.max(1,Math.ceil(selection.records.length/25))}</span><Button disabled={(page+1)*25>=selection.records.length} onClick={()=>setPage(p=>p+1)}>Next</Button></div>
    </Card>}
  </>
}

function Chart({ metric, buckets, inspect }: { metric: Metric; buckets: Bucket[]; inspect: (b:Bucket)=>void }) {
  const max = Math.max(1,...buckets.map(b=>Number(b.value)))
  const total = buckets.reduce((s,b)=>s+Number(b.value),0)
  return <>
    {metric.chart==='donut' && total>0 && <svg viewBox="0 0 200 200" className="mx-auto mb-4 h-44 w-44" role="img" aria-label={metric.title}>
      {buckets.map((b,i)=>{ const length=Number(b.value)/total*100; const start=buckets.slice(0,i).reduce((sum,x)=>sum+Number(x.value)/total*100,0); return <circle key={b.label} cx="100" cy="100" r="70" fill="none" stroke={colors[i%colors.length]} strokeWidth="28" pathLength="100" strokeDasharray={length+' '+(100-length)} strokeDashoffset={-start} transform="rotate(-90 100 100)" onClick={()=>inspect(b)} className="cursor-pointer"><title>{b.label+': '+fmt(b.value)}</title></circle> })}
      <text x="100" y="105" textAnchor="middle" fill="currentColor" fontSize="15">{fmt(total)}</text>
    </svg>}
    {metric.chart==='line' && <svg viewBox="0 0 500 150" className="mb-3 h-36 w-full" role="img" aria-label={metric.title}>
      <line x1="20" y1="130" x2="480" y2="130" stroke="currentColor" opacity=".25" />
      <polyline fill="none" stroke="#2563eb" strokeWidth="3" points={buckets.map((b,i)=>(20+i*460/Math.max(1,buckets.length-1))+','+(130-Number(b.value)/max*110)).join(' ')} />
      {buckets.map((b,i)=><circle key={b.label} cx={20+i*460/Math.max(1,buckets.length-1)} cy={130-Number(b.value)/max*110} r="5" fill="#2563eb" className="cursor-pointer" onClick={()=>inspect(b)}><title>{b.label+': '+fmt(b.value)}</title></circle>)}
    </svg>}
    <div className="max-h-72 space-y-2 overflow-auto">{buckets.map((b,i)=><button className="block w-full rounded p-1 text-left hover:bg-subtle focus-visible:outline" key={b.label} onClick={()=>inspect(b)}>
      <span className="flex justify-between gap-4 text-xs"><span><span style={{color:colors[i%colors.length]}}>● </span>{b.label}</span><span>{fmt(b.value)} {b.currency}</span></span>
      {metric.chart==='bar' && <span className="mt-1 block h-3 rounded bg-muted"><span className="block h-3 rounded" style={{width:(Number(b.value)/max*100)+'%',background:colors[i%colors.length]}} /></span>}
    </button>)}</div>
  </>
}
