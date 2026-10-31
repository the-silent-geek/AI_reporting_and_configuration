import clsx from 'clsx'
import { CheckCircle2, Info, XCircle } from 'lucide-react'
import { AnimatePresence, motion } from 'motion/react'
import { createContext, useCallback, useContext, useState, type ReactNode } from 'react'

type Tone = 'success' | 'error' | 'info'
interface Toast { id: number; tone: Tone; title: string; description?: string }

const ToastContext = createContext<(t: Omit<Toast, 'id'>) => void>(() => {})
let seq = 0

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const push = useCallback((t: Omit<Toast, 'id'>) => {
    const id = ++seq
    setToasts((all) => [...all.slice(-2), { ...t, id }])          // max 3 on screen
    setTimeout(() => setToasts((all) => all.filter((x) => x.id !== id)), 4500)
  }, [])

  const Icon = { success: CheckCircle2, error: XCircle, info: Info }
  return (
    <ToastContext.Provider value={push}>
      {children}
      <div aria-live="polite" className="pointer-events-none fixed inset-x-0 bottom-0 z-[60] flex flex-col items-center gap-2 p-4 sm:items-end">
        <AnimatePresence initial={false}>
          {toasts.map((t) => {
            const I = Icon[t.tone]
            return (
              <motion.div key={t.id} layout
                initial={{ opacity: 0, y: 16, scale: 0.98 }} animate={{ opacity: 1, y: 0, scale: 1 }}
                exit={{ opacity: 0, x: 24, transition: { duration: 0.15 } }}
                transition={{ type: 'spring', stiffness: 400, damping: 32 }}
                className="pointer-events-auto flex w-full max-w-sm items-start gap-3 rounded-xl border border-border bg-surface p-4 shadow-xl shadow-black/5">
                <I className={clsx('mt-0.5 size-4 shrink-0',
                  t.tone === 'success' ? 'text-success' : t.tone === 'error' ? 'text-danger' : 'text-fg-muted')} />
                <div className="min-w-0">
                  <p className="text-sm font-medium">{t.title}</p>
                  {t.description && <p className="mt-0.5 text-sm text-fg-muted">{t.description}</p>}
                </div>
              </motion.div>
            )
          })}
        </AnimatePresence>
      </div>
    </ToastContext.Provider>
  )
}

export const useToast = () => useContext(ToastContext)
