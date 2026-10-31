import clsx from 'clsx'
import { Database, RefreshCw, Search, Upload } from 'lucide-react'
import { motion } from 'motion/react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Button } from '../../components/ui/Button'
import { inputClass } from '../../components/ui/Field'
import { Card, EmptyState, PageHeader, Skeleton } from '../../components/ui/Misc'
import { useApp } from '../../lib/appContext'
import type { BatchStatus } from '../../lib/types'
import { BatchTable, useBatches } from './batches'

const FILTERS: { key: string; label: string; match: (s: BatchStatus) => boolean }[] = [
  { key: 'all', label: 'All', match: () => true },
  { key: 'progress', label: 'Processing', match: (s) => ['UPLOADED', 'EXTRACTING', 'MAPPING_REVIEW', 'VALIDATING'].includes(s) },
  { key: 'review', label: 'Needs action', match: (s) => s === 'READY_TO_COMMIT' || s === 'NEEDS_REVIEW' },
  { key: 'done', label: 'Committed', match: (s) => s === 'COMMITTED' },
  { key: 'failed', label: 'Failed', match: (s) => s === 'FAILED' },
]

export function Datasets() {
  const { app, can } = useApp()
  const { batches, reload } = useBatches()
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState('all')
  const [spinning, setSpinning] = useState(false)

  const shown = useMemo(() => {
    const f = FILTERS.find((x) => x.key === filter)!
    const q = query.trim().toLowerCase()
    return (batches ?? []).filter((b) => f.match(b.status) &&
      (!q || b.file_name.toLowerCase().includes(q) || b.batch_code.toLowerCase().includes(q)))
  }, [batches, filter, query])

  return (
    <>
      <PageHeader title="Datasets" description="Every uploaded file, its processing status and record counts."
                  actions={<>
                    <Button size="icon" variant="ghost" aria-label="Refresh"
                            onClick={async () => { setSpinning(true); await reload(); setTimeout(() => setSpinning(false), 400) }}>
                      <RefreshCw className={clsx('size-4', spinning && 'animate-spin')} strokeWidth={1.75} />
                    </Button>
                    {can('dataset.upload') && (
                      <Link to={`${app.route}/datasets/upload`}><Button variant="primary" icon={Upload}>Upload file</Button></Link>
                    )}
                  </>} />

      <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div role="tablist" aria-label="Filter by status" className="-mx-1 flex gap-1 overflow-x-auto px-1 [scrollbar-width:none]">
          {FILTERS.map((f) => (
            <button key={f.key} role="tab" aria-selected={filter === f.key} onClick={() => setFilter(f.key)}
                    className={clsx('relative h-8 rounded-md px-3 text-[13px] whitespace-nowrap transition-colors',
                      filter === f.key ? 'font-medium text-fg' : 'text-fg-muted hover:text-fg')}>
              {filter === f.key && <motion.span layoutId="ds-filter" className="absolute inset-0 rounded-md bg-muted"
                                                transition={{ type: 'spring', stiffness: 400, damping: 34 }} />}
              <span className="relative">{f.label}</span>
            </button>
          ))}
        </div>
        <div className="relative sm:w-72">
          <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-fg-subtle" />
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search file or batch"
                 aria-label="Search batches" className={clsx(inputClass, 'h-9 pl-9')} />
        </div>
      </div>

      <Card className="overflow-hidden">
        {!batches ? (
          <div className="space-y-3 p-5">{Array.from({ length: 6 }, (_, i) => <Skeleton key={i} className="h-9" />)}</div>
        ) : shown.length ? <BatchTable batches={shown} /> : (
          <EmptyState icon={Database} title={batches.length ? 'No matching uploads' : 'No uploads yet'}>
            {batches.length ? 'Try a different filter or search.' : 'Files you upload will appear here.'}
          </EmptyState>
        )}
      </Card>
    </>
  )
}
