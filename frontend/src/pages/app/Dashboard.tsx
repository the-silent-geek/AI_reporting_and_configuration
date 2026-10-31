import { ArrowRight, CheckCircle2, Database, Loader, Upload, XCircle } from 'lucide-react'
import { motion } from 'motion/react'
import { Link } from 'react-router-dom'
import { Button } from '../../components/ui/Button'
import { Card, EmptyState, PageHeader, Skeleton } from '../../components/ui/Misc'
import { useApp } from '../../lib/appContext'
import { isInProgress } from '../../lib/format'
import { BatchTable, useBatches } from './batches'

export function Dashboard() {
  const { app, can } = useApp()
  const { batches } = useBatches()

  const stats = batches && [
    { label: 'Uploads', value: batches.length, icon: Database },
    { label: 'Committed', value: batches.filter((b) => b.status === 'COMMITTED').length, icon: CheckCircle2 },
    { label: 'In progress', value: batches.filter((b) => isInProgress(b.status) || ['MAPPING_REVIEW', 'READY_TO_COMMIT', 'NEEDS_REVIEW'].includes(b.status)).length, icon: Loader },
    { label: 'Failed', value: batches.filter((b) => b.status === 'FAILED').length, icon: XCircle },
  ]

  return (
    <>
      <PageHeader title={`${app.name} overview`} description="Ingestion activity for this application."
                  actions={can('dataset.upload') && (
                    <Link to={`${app.route}/datasets/upload`}><Button variant="primary" icon={Upload}>Upload file</Button></Link>
                  )} />

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4 lg:gap-4">
        {stats ? stats.map((s, i) => (
          <motion.div key={s.label} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: i * 0.05 }}>
            <Card className="p-4 sm:p-5">
              <div className="flex items-center justify-between text-fg-muted">
                <span className="text-xs font-medium sm:text-sm">{s.label}</span>
                <s.icon className="size-4" strokeWidth={1.5} />
              </div>
              <p className="mt-3 text-2xl font-semibold tracking-tight tabular sm:text-3xl">{s.value}</p>
            </Card>
          </motion.div>
        )) : Array.from({ length: 4 }, (_, i) => <Skeleton key={i} className="h-[104px] rounded-xl" />)}
      </div>

      <Card className="mt-6 overflow-hidden">
        <div className="flex items-center justify-between border-b border-border px-5 py-4">
          <div>
            <h2 className="text-sm font-semibold">Recent uploads</h2>
            <p className="text-xs text-fg-muted">Latest files and where they are in the pipeline</p>
          </div>
          <Link to={`${app.route}/datasets`} className="group inline-flex items-center gap-1 text-sm text-fg-muted transition-colors hover:text-fg">
            View all <ArrowRight className="size-3.5 transition-transform group-hover:translate-x-0.5" />
          </Link>
        </div>
        {!batches ? (
          <div className="space-y-3 p-5">{Array.from({ length: 4 }, (_, i) => <Skeleton key={i} className="h-9" />)}</div>
        ) : batches.length ? <BatchTable batches={batches.slice(0, 6)} /> : (
          <EmptyState icon={Database} title="No uploads yet"
                      action={can('dataset.upload') && <Link to={`${app.route}/datasets/upload`}><Button icon={Upload}>Upload the first file</Button></Link>}>
            Uploaded files appear here with their live processing status.
          </EmptyState>
        )}
      </Card>
    </>
  )
}
