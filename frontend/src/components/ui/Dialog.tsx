import { X } from 'lucide-react'
import { AnimatePresence, motion } from 'motion/react'
import { useEffect, useRef, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

/** Modal: fades + scales in, closes on Esc / backdrop, keeps focus inside, restores it after. */
export function Dialog({ open, onClose, title, description, children, footer }: {
  open: boolean
  onClose: () => void
  title: string
  description?: ReactNode
  children?: ReactNode
  footer?: ReactNode
}) {
  const panel = useRef<HTMLDivElement>(null)
  // Parents pass a new onClose every render. Keep it in a ref so the effect below runs
  // only when the dialog opens/closes - otherwise focus jumped back to the first input
  // on every keystroke.
  const onCloseRef = useRef(onClose)
  useEffect(() => { onCloseRef.current = onClose })

  useEffect(() => {
    if (!open) return
    const previous = document.activeElement as HTMLElement | null
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onCloseRef.current()
      if (e.key === 'Tab' && panel.current) {
        const items = panel.current.querySelectorAll<HTMLElement>(
          'button:not([disabled]), input:not([disabled]), select, textarea, a[href], [tabindex]:not([tabindex="-1"])')
        if (!items.length) return
        const first = items[0]!, last = items[items.length - 1]!
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus() }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus() }
      }
    }
    document.addEventListener('keydown', onKey)
    document.body.style.overflow = 'hidden'
    requestAnimationFrame(() => panel.current?.querySelector<HTMLElement>('input, button[data-autofocus]')?.focus())
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = ''
      previous?.focus()
    }
  }, [open])

  return createPortal(
    <AnimatePresence>
      {open && (
        <div className="fixed inset-0 z-50 flex items-end justify-center p-0 sm:items-center sm:p-4">
          <motion.div className="absolute inset-0 bg-black/40 backdrop-blur-[2px]" onClick={onClose}
                      initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} />
          <motion.div
            ref={panel} role="dialog" aria-modal="true" aria-label={title}
            className="relative w-full max-w-md rounded-t-2xl border border-border bg-surface shadow-2xl sm:rounded-2xl"
            initial={{ opacity: 0, y: 24, scale: 0.98 }} animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 16, scale: 0.98 }} transition={{ type: 'spring', stiffness: 380, damping: 32 }}
          >
            <div className="flex items-start justify-between gap-4 px-6 pt-5">
              <div>
                <h2 className="text-base font-semibold">{title}</h2>
                {description && <p className="mt-1 text-sm text-fg-muted">{description}</p>}
              </div>
              <button onClick={onClose} aria-label="Close"
                      className="-mr-2 rounded-md p-1.5 text-fg-muted transition-colors hover:bg-muted hover:text-fg">
                <X className="size-4" />
              </button>
            </div>
            {children && <div className="px-6 py-5">{children}</div>}
            {footer && <div className="flex justify-end gap-2 border-t border-border px-6 py-4">{footer}</div>}
          </motion.div>
        </div>
      )}
    </AnimatePresence>,
    document.body,
  )
}
