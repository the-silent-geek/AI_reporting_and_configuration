import clsx from 'clsx'
import { ArrowLeft, CloudUpload, X } from 'lucide-react'
import { AnimatePresence, motion } from 'motion/react'
import { useRef, useState, type DragEvent, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Button } from '../../components/ui/Button'
import { Field } from '../../components/ui/Field'
import { Card, PageHeader, ProgressBar } from '../../components/ui/Misc'
import { useToast } from '../../components/ui/Toast'
import { uploadFile } from '../../lib/api'
import { useApp } from '../../lib/appContext'
import { fmtBytes } from '../../lib/format'
import { FILE_ICON } from './batches'

const TYPES: Record<string, keyof typeof FILE_ICON> = { csv: 'CSV', xlsx: 'EXCEL', xls: 'EXCEL', json: 'JSON', pdf: 'PDF' }
const MAX_MB = 50

function typeOf(name: string) { return TYPES[name.split('.').pop()?.toLowerCase() ?? ''] }

export function Upload() {
  const { app, code } = useApp()
  const navigate = useNavigate()
  const toast = useToast()
  const input = useRef<HTMLInputElement>(null)
  const [file, setFile] = useState<File | null>(null)
  const [drag, setDrag] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [progress, setProgress] = useState<number | null>(null)
  const [meta, setMeta] = useState({ source_system: '', period_start: '', period_end: '' })

  function pick(f: File | undefined) {
    if (!f) return
    setError(null)
    if (!typeOf(f.name)) return setError('Only CSV, Excel (.xlsx/.xls), JSON and PDF files are supported.')
    if (f.size > MAX_MB * 1024 * 1024) return setError(`File is larger than ${MAX_MB} MB.`)
    if (f.size === 0) return setError('This file is empty.')
    setFile(f)
  }

  function onDrop(e: DragEvent) {
    e.preventDefault(); setDrag(false)
    pick(e.dataTransfer.files[0])
  }

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (!file) return
    if (meta.period_start && meta.period_end && meta.period_end < meta.period_start) {
      return setError('Period end must be after period start.')
    }
    const form = new FormData()
    form.append('file', file)
    Object.entries(meta).forEach(([k, v]) => v && form.append(k, v))
    setProgress(0); setError(null)
    try {
      const { status, body } = await uploadFile(`/api/apps/${code}/batches`, form, setProgress)
      if (status === 201) {
        toast({ tone: 'success', title: 'Upload complete', description: 'Processing has started.' })
        navigate(`${app.route}/datasets/${body.batch_id}`)
      } else if (status === 200 && body?.status === 'DUPLICATE') {
        toast({ tone: 'info', title: 'Already uploaded', description: 'Opening the existing batch for this file.' })
        navigate(`${app.route}/datasets/${body.batch_id}`)
      } else {
        setError(typeof body?.detail === 'string' ? body.detail : `Upload failed (${status}).`)
        setProgress(null)
      }
    } catch {
      setError('Network error during upload. Please retry.')
      setProgress(null)
    }
  }

  const Icon = file ? FILE_ICON[typeOf(file.name)!] : CloudUpload
  const busy = progress !== null

  return (
    <div className="mx-auto max-w-2xl">
      <Link to={`${app.route}/datasets`} className="mb-4 inline-flex items-center gap-1.5 text-sm text-fg-muted transition-colors hover:text-fg">
        <ArrowLeft className="size-4" /> Datasets
      </Link>
      <PageHeader title="Upload file" description="CSV, Excel, JSON or PDF, up to 50 MB. The original file is kept unchanged for audit." />

      <form onSubmit={submit}>
        <Card className="p-5 sm:p-6">
          <div
            onDragOver={(e) => { e.preventDefault(); setDrag(true) }} onDragLeave={() => setDrag(false)} onDrop={onDrop}
            onClick={() => !busy && input.current?.click()}
            onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && !busy && input.current?.click()}
            role="button" tabIndex={0} aria-label="Choose a file or drop it here"
            className={clsx('relative flex cursor-pointer flex-col items-center justify-center rounded-xl border border-dashed px-6 py-12 text-center transition-all duration-200',
              drag ? 'scale-[1.01] border-fg bg-muted' : 'border-border-strong hover:border-fg/40 hover:bg-subtle',
              busy && 'pointer-events-none opacity-70')}
          >
            <input ref={input} type="file" hidden accept=".csv,.xlsx,.xls,.json,.pdf" onChange={(e) => pick(e.target.files?.[0])} />
            <motion.div key={file?.name ?? 'empty'} initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
                        className="mb-4 flex size-12 items-center justify-center rounded-xl border border-border bg-surface shadow-sm">
              <Icon className="size-5" strokeWidth={1.5} />
            </motion.div>
            {file ? (
              <>
                <p className="max-w-full truncate text-sm font-medium">{file.name}</p>
                <p className="mt-1 text-xs text-fg-muted">{typeOf(file.name)} · {fmtBytes(file.size)}</p>
                {!busy && (
                  <button type="button" onClick={(e) => { e.stopPropagation(); setFile(null) }}
                          className="mt-3 inline-flex items-center gap-1 text-xs text-fg-muted underline-offset-4 hover:text-fg hover:underline">
                    <X className="size-3" /> Remove
                  </button>
                )}
              </>
            ) : (
              <>
                <p className="text-sm font-medium">Drop a file here or <span className="underline underline-offset-4">browse</span></p>
                <p className="mt-1 text-xs text-fg-muted">CSV · XLSX · JSON · PDF</p>
              </>
            )}
          </div>

          <AnimatePresence>
            {error && (
              <motion.p role="alert" initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }} exit={{ opacity: 0, height: 0 }}
                        className="mt-3 overflow-hidden text-sm text-danger">{error}</motion.p>
            )}
          </AnimatePresence>

          <fieldset disabled={busy} className="mt-6 grid gap-4 sm:grid-cols-2">
            <Field label="Source system" placeholder="e.g. SAP" maxLength={100} className="sm:col-span-2"
                   value={meta.source_system} onChange={(e) => setMeta({ ...meta, source_system: e.target.value })}
                   hint="Optional. Where this file was exported from." />
            <Field label="Period start" type="date" value={meta.period_start}
                   onChange={(e) => setMeta({ ...meta, period_start: e.target.value })} />
            <Field label="Period end" type="date" value={meta.period_end}
                   onChange={(e) => setMeta({ ...meta, period_end: e.target.value })} />
          </fieldset>

          <AnimatePresence>
            {busy && (
              <motion.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }} exit={{ opacity: 0, height: 0 }} className="overflow-hidden">
                <div className="mt-6 flex items-center gap-3">
                  <ProgressBar value={progress ?? 0} />
                  <span className="w-10 text-right text-xs text-fg-muted tabular">{progress}%</span>
                </div>
              </motion.div>
            )}
          </AnimatePresence>

          <div className="mt-6 flex justify-end gap-2 border-t border-border pt-5">
            <Link to={`${app.route}/datasets`}><Button type="button" variant="ghost" disabled={busy}>Cancel</Button></Link>
            <Button type="submit" variant="primary" disabled={!file} loading={busy} icon={CloudUpload}>
              {busy ? (progress === 100 ? 'Registering…' : 'Uploading…') : 'Upload'}
            </Button>
          </div>
        </Card>
      </form>
    </div>
  )
}
