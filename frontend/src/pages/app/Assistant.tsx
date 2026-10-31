import clsx from 'clsx'
import { Link } from 'react-router-dom'
import { ArrowUp, ChevronDown, Info, Plus, Sparkles } from 'lucide-react'
import { AnimatePresence, motion } from 'motion/react'
import { useEffect, useRef, useState, type FormEvent, type KeyboardEvent } from 'react'
import { Button } from '../../components/ui/Button'
import { Card, PageHeader } from '../../components/ui/Misc'
import { ApiError, api, json } from '../../lib/api'
import { useApp } from '../../lib/appContext'

/* Smart Assistance chat (docs_ai/02). The backend plans with Groq, runs one allowlisted
   DB tool, and answers only from that tool's result. Every data answer shows where its
   numbers came from: period, filters, metric definitions and the result reference. */

interface ToolResult {
  result_reference: string
  reporting_period: string
  filters: Record<string, unknown>
  metric_definitions: { metric: string; definition: string }[]
  kpis: Record<string, unknown>
  chart_data: Record<string, unknown>[]
  supporting_rows: Record<string, unknown>[]
}

interface ChatReply {
  conversation_id: string
  status: 'answered' | 'clarification' | 'refused' | 'error'
  answer: string | null
  grounded: boolean | null
  result: ToolResult | null
}

type Message = { role: 'user'; text: string } | { role: 'assistant'; reply: ChatReply }

const SUGGESTIONS: Record<string, string[]> = {
  erp: ['What are the overdue payables by ageing bucket as of today?', 'Which suppliers have the most overdue?',
        'Show overdue payments'],
  lending: ['How many loan applications were rejected last month?', 'Monthly application trend this year',
            'Show details of an application'],
  aml: ['How many alerts were raised this month by severity?', 'Open HIGH severity alerts this quarter',
        'Show details of a case'],
}

const label = (key: string) => key.replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase())

function fmt(v: unknown): string {
  if (typeof v === 'number') return v.toLocaleString(undefined, { maximumFractionDigits: 2 })
  if (v === null || v === undefined || v === '') return '–'
  if (typeof v === 'object') return JSON.stringify(v)
  return String(v)
}

export function Assistant() {
  const { app, code } = useApp()
  const [messages, setMessages] = useState<Message[]>([])
  const [conversationId, setConversationId] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [busy, setBusy] = useState(false)
  const bottom = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLTextAreaElement>(null)

  useEffect(() => { bottom.current?.scrollIntoView({ behavior: 'smooth', block: 'end' }) }, [messages, busy])

  async function send(text: string) {
    const message = text.trim()
    if (!message || busy) return
    setDraft('')
    setMessages((m) => [...m, { role: 'user', text: message }])
    setBusy(true)
    try {
      const reply = await api<ChatReply>(`/api/apps/${code}/assistant/chat`, {
        method: 'POST', ...json({ message, ...(conversationId ? { conversation_id: conversationId } : {}) }),
      })
      setConversationId(reply.conversation_id)
      setMessages((m) => [...m, { role: 'assistant', reply }])
    } catch (e) {
      const text = e instanceof ApiError && e.status === 503 ? 'Smart Assistance is not configured on the server yet.'
        : e instanceof ApiError && e.status === 403 ? "You don't have access to Smart Assistance in this app."
        : e instanceof ApiError && e.status === 404 ? 'This conversation has ended. Start a new chat.'
        : 'Something went wrong. Please try again.'
      setMessages((m) => [...m, { role: 'assistant', reply: { conversation_id: '', status: 'error', answer: text,
                                                              grounded: null, result: null } }])
    } finally {
      setBusy(false)
      input.current?.focus()
    }
  }

  function onSubmit(e: FormEvent) { e.preventDefault(); send(draft) }
  function onKey(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); send(draft) }
  }
  function newChat() { setMessages([]); setConversationId(null); setDraft(''); input.current?.focus() }

  return (
    <div className="flex h-full min-h-[calc(100dvh-8rem)] flex-col">
      <PageHeader title="Smart assistance" description={`Ask questions about ${app.name} data. Answers come only from your authorized data.`}
                  actions={messages.length > 0 && <Button icon={Plus} onClick={newChat} disabled={busy}>New chat</Button>} />

      <Card className="flex min-h-0 flex-1 flex-col overflow-hidden">
        <div className="min-h-0 flex-1 space-y-5 overflow-y-auto p-4 sm:p-6" aria-live="polite">
          {messages.length === 0 && (
            <div className="flex flex-col items-center px-2 py-10 text-center">
              <div className="mb-4 flex size-12 items-center justify-center rounded-xl border border-border bg-subtle">
                <Sparkles className="size-5 text-fg-muted" strokeWidth={1.5} />
              </div>
              <h2 className="text-sm font-semibold">What would you like to know?</h2>
              <p className="mt-1 max-w-md text-sm text-fg-muted">
                Every number is calculated by the database. If something is unclear, I'll ask first.
              </p>
              <div className="mt-6 flex w-full max-w-xl flex-col gap-2">
                {(SUGGESTIONS[code] ?? []).map((s) => (
                  <button key={s} onClick={() => send(s)}
                          className="rounded-lg border border-border px-4 py-2.5 text-left text-sm text-fg-muted transition-colors hover:border-border-strong hover:bg-muted hover:text-fg">
                    {s}
                  </button>
                ))}
              </div>
            </div>
          )}

          <AnimatePresence initial={false}>
            {messages.map((m, i) => (
              <motion.div key={i} initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }}
                          className={clsx('flex', m.role === 'user' ? 'justify-end' : 'justify-start')}>
                {m.role === 'user'
                  ? <div className="max-w-[85%] rounded-2xl rounded-br-md bg-accent px-4 py-2.5 text-sm whitespace-pre-wrap text-accent-fg">{m.text}</div>
                  : <AssistantMessage reply={m.reply} />}
              </motion.div>
            ))}
          </AnimatePresence>

          {busy && (
            <div className="flex items-center gap-2 text-sm text-fg-muted">
              <span className="flex gap-1">
                {[0, 1, 2].map((d) => (
                  <motion.span key={d} className="size-1.5 rounded-full bg-fg-subtle"
                               animate={{ opacity: [0.3, 1, 0.3] }} transition={{ duration: 1, repeat: Infinity, delay: d * 0.15 }} />
                ))}
              </span>
              Looking into it…
            </div>
          )}
          <div ref={bottom} />
        </div>

        <form onSubmit={onSubmit} className="border-t border-border p-3 sm:p-4">
          <div className="flex items-end gap-2 rounded-xl border border-border bg-surface p-2 transition-[border-color,box-shadow] focus-within:border-fg focus-within:ring-4 focus-within:ring-fg/5">
            <textarea ref={input} value={draft} onChange={(e) => setDraft(e.target.value)} onKeyDown={onKey}
                      rows={1} maxLength={1000} placeholder="Ask about your data…" aria-label="Your question"
                      className="max-h-40 min-h-9 flex-1 resize-none bg-transparent px-2 py-1.5 text-sm placeholder:text-fg-subtle focus:outline-none [field-sizing:content]" />
            <Button type="submit" variant="primary" size="icon" loading={busy} disabled={!draft.trim()} aria-label="Send">
              {!busy && <ArrowUp className="size-4" />}
            </Button>
          </div>
          <p className="mt-2 px-1 text-[11px] text-fg-subtle">Enter to send · Shift+Enter for a new line</p>
        </form>
      </Card>
    </div>
  )
}

function AssistantMessage({ reply }: { reply: ChatReply }) {
  const muted = reply.status === 'refused' || reply.status === 'error'
  return (
    <div className="w-full max-w-[85%] space-y-3">
      <div className={clsx('rounded-2xl rounded-bl-md border px-4 py-2.5 text-sm whitespace-pre-wrap',
        reply.status === 'clarification' ? 'border-border-strong bg-subtle' : 'border-border bg-surface',
        muted && 'text-fg-muted')}>
        {reply.status === 'clarification' && <span className="mb-1 block text-[11px] font-medium uppercase tracking-wide text-fg-subtle">Question for you</span>}
        {reply.answer}
      </div>
      {reply.result && <ResultDetails result={reply.result} grounded={reply.grounded} />}
    </div>
  )
}

function Kpi({ name, value }: { name: string; value: unknown }) {
  const amounts = value && typeof value === 'object' && !Array.isArray(value) ? Object.entries(value) : null
  return (
    <div className="min-w-0 rounded-lg border border-border px-3 py-2">
      <p className="truncate text-[11px] text-fg-muted">{label(name)}</p>
      {amounts
        ? amounts.length
          ? amounts.map(([k, v]) => <p key={k} className="text-sm font-semibold tabular">{k} {fmt(v)}</p>)
          : <p className="text-sm font-semibold">–</p>
        : <p className="text-sm font-semibold tabular">{fmt(value)}</p>}
    </div>
  )
}

function ResultDetails({ result, grounded }: { result: ToolResult; grounded: boolean | null }) {
  const { app, code, can } = useApp()
  const recordTypes: Record<string, Record<string,string>> = {
    lending: { application_id: 'application', disbursement_id: 'disbursement' },
    erp: { invoice_id: 'invoice', payment_id: 'payment', supplier_id: 'supplier' },
    aml: { alert_id: 'alert', case_id: 'investigation_case' },
  }
  const [open, setOpen] = useState(false)
  const kpis = Object.entries(result.kpis).filter(([k]) => k !== 'found')
  const rows = result.supporting_rows.length ? result.supporting_rows : result.chart_data
  const columns = [...new Set(rows.flatMap((r) => Object.keys(r)))].slice(0, 8)
  const filters = Object.entries(result.filters).filter(([, v]) => v !== null && v !== undefined)

  return (
    <div className="space-y-2">
      {kpis.length > 0 && (
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
          {kpis.map(([k, v]) => <Kpi key={k} name={k} value={v} />)}
        </div>
      )}

      {rows.length > 0 && (
        <div className="rounded-lg border border-border">
          <button onClick={() => setOpen((o) => !o)} aria-expanded={open}
                  className="flex w-full items-center justify-between px-3 py-2 text-xs font-medium text-fg-muted hover:text-fg">
            {open ? 'Hide' : 'Show'} {rows.length} supporting row{rows.length === 1 ? '' : 's'}
            <ChevronDown className={clsx('size-3.5 transition-transform', open && 'rotate-180')} />
          </button>
          {open && (
            <div className="overflow-x-auto border-t border-border">
              <table className="w-full text-left text-xs">
                <thead className="bg-subtle text-fg-muted">
                  <tr>{columns.map((c) => <th key={c} className="px-3 py-2 font-medium whitespace-nowrap">{label(c)}</th>)}</tr>
                </thead>
                <tbody>
                  {rows.map((r, i) => (
                    <tr key={i} className="border-t border-border">
                      {columns.map((c) => <td key={c} className={clsx('px-3 py-1.5 whitespace-nowrap', typeof r[c] === 'number' && 'text-right tabular')}>
                        {recordTypes[code]?.[c] && r[c] != null && can('template.view') && can('report.generate')
                          ? <Link target="_blank" rel="noopener noreferrer" className="underline underline-offset-2 hover:text-fg" title="Open record template in a new tab" to={`${app.route}/templates/record?${new URLSearchParams({entity:recordTypes[code][c],key:String(r[c])})}`}>{fmt(r[c])} ↗</Link>
                          : fmt(r[c])}
                      </td>)}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      <details className="group rounded-lg px-1 text-[11px] text-fg-muted">
        <summary className="flex cursor-pointer list-none items-center gap-1.5 hover:text-fg">
          <Info className="size-3" />
          {result.reporting_period}
          {filters.length > 0 && <> · {filters.map(([k, v]) => `${label(k)}: ${fmt(v)}`).join(' · ')}</>}
          {grounded === false && <> · shown as calculated (AI summary not used)</>}
        </summary>
        <div className="mt-2 space-y-1.5 border-l border-border pl-3">
          {result.metric_definitions.map((d) => (
            <p key={d.metric}><span className="font-medium text-fg">{label(d.metric)}:</span> {d.definition}</p>
          ))}
          <p>Result reference: <code className="text-fg">{result.result_reference}</code></p>
        </div>
      </details>
    </div>
  )
}
