import { FileJson, FileSpreadsheet, FileText, FileType } from 'lucide-react'
import { motion } from 'motion/react'
import { useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { ProgressBar, StatusBadge } from '../../components/ui/Misc'
import { api } from '../../lib/api'
import { useApp } from '../../lib/appContext'
import { fmtRelative, isInProgress } from '../../lib/format'
import type { BatchSummary } from '../../lib/types'

export const FILE_ICON = { CSV: FileText, EXCEL: FileSpreadsheet, JSON: FileJson, PDF: FileType }

/** Batch list for the current app; re-polls every 4 s while anything is still processing. */
export function useBatches() {
  const { code } = useApp()
  const [batches, setBatches] = useState<BatchSummary[] | null>(null)
  const [error, setError] = useState(false)

  const load = useCallback(async () => {
    try { setBatches(await api<BatchSummary[]>(`/api/apps/${code}/batches?limit=200`)); setError(false) }
    catch { setError(true) }
  }, [code])

  useEffect(() => { load() }, [load])
  const busy = batches?.some((b) => isInProgress(b.status))
  useEffect(() => {
    if (!busy) return
    const t = setInterval(load, 4000)
    return () => clearInterval(t)
  }, [busy, load])

  return { batches, error, reload: load }
}

export function BatchTable({ batches }: { batches: BatchSummary[] }) {
  const { app } = useApp()
  const navigate = useNavigate()
  const open = (b: BatchSummary) => navigate(`${app.route}/datasets/${b.batch_id}`)

  return (
    <>
      {/* Desktop table */}
      <table className="hidden w-full table-fixed text-sm md:table">
        <thead>
          <tr className="border-b border-border text-left text-xs text-fg-muted">
            <th className="w-32 py-3 pr-4 pl-5 font-medium">Batch</th>
            <th className="px-4 py-3 font-medium">File</th>
            <th className="w-40 px-4 py-3 font-medium">Status</th>
            {/* progress bar column only where there is room; status badge already says where it is */}
            <th className="hidden w-48 px-4 py-3 font-medium xl:table-cell">Progress</th>
            <th className="w-28 py-3 pr-5 pl-4 text-right font-medium">Uploaded</th>
          </tr>
        </thead>
        <tbody>
          {batches.map((b, i) => {
            const Icon = FILE_ICON[b.file_type]
            return (
              <motion.tr key={b.batch_id} onClick={() => open(b)}
                         initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: Math.min(i, 12) * 0.02 }}
                         tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && open(b)}
                         className="cursor-pointer border-b border-border last:border-0 transition-colors hover:bg-subtle focus-visible:bg-subtle">
                <td className="py-3 pr-4 pl-5 font-mono text-xs text-fg-muted tabular">{b.batch_code}</td>
                <td className="px-4 py-3">
                  <span className="flex items-center gap-2.5">
                    <Icon className="size-4 shrink-0 text-fg-subtle" strokeWidth={1.5} />
                    <span className="truncate font-medium">{b.file_name}</span>
                  </span>
                </td>
                <td className="px-4 py-3"><StatusBadge status={b.status} /></td>
                <td className="hidden px-4 py-3 xl:table-cell">
                  <div className="flex items-center gap-3">
                    <ProgressBar value={b.status === 'COMMITTED' ? 100 : b.progress_pct} />
                    <span className="w-9 text-right text-xs text-fg-muted tabular">{b.status === 'COMMITTED' ? 100 : b.progress_pct}%</span>
                  </div>
                </td>
                <td className="py-3 pr-5 pl-4 text-right whitespace-nowrap text-fg-muted" title={new Date(b.uploaded_at).toLocaleString()}>
                  {fmtRelative(b.uploaded_at)}
                </td>
              </motion.tr>
            )
          })}
        </tbody>
      </table>

      {/* Mobile list */}
      <ul className="divide-y divide-border md:hidden">
        {batches.map((b) => {
          const Icon = FILE_ICON[b.file_type]
          return (
            <li key={b.batch_id}>
              <button onClick={() => open(b)} className="flex w-full items-start gap-3 px-4 py-3.5 text-left transition-colors active:bg-subtle">
                <Icon className="mt-0.5 size-4 shrink-0 text-fg-subtle" strokeWidth={1.5} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-medium">{b.file_name}</span>
                  <span className="mt-0.5 block text-xs text-fg-muted">{b.batch_code} · {fmtRelative(b.uploaded_at)}</span>
                  {isInProgress(b.status) && <ProgressBar value={b.progress_pct} className="mt-2" />}
                </span>
                <StatusBadge status={b.status} />
              </button>
            </li>
          )
        })}
      </ul>
    </>
  )
}
