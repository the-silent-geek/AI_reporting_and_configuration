import clsx from 'clsx'
import { AnimatePresence, motion } from 'motion/react'
import { useEffect, useRef, useState, type ReactNode } from 'react'

/** Small dropdown: opens on click, closes on outside click / Esc / item click. */
export function Menu({ trigger, children, align = 'end', side = 'bottom', className }: {
  trigger: (props: { open: boolean; toggle: () => void }) => ReactNode
  children: ReactNode | ((close: () => void) => ReactNode)
  align?: 'start' | 'end'
  side?: 'bottom' | 'top'
  className?: string
}) {
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => { if (!root.current?.contains(e.target as Node)) setOpen(false) }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => { document.removeEventListener('mousedown', onDown); document.removeEventListener('keydown', onKey) }
  }, [open])

  const close = () => setOpen(false)
  return (
    <div ref={root} className="relative">
      {trigger({ open, toggle: () => setOpen((o) => !o) })}
      <AnimatePresence>
        {open && (
          <motion.div
            role="menu"
            initial={{ opacity: 0, y: side === 'bottom' ? -4 : 4, scale: 0.98 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: side === 'bottom' ? -4 : 4, scale: 0.98 }}
            transition={{ duration: 0.16, ease: [0.22, 1, 0.36, 1] }}
            className={clsx(
              'absolute z-40 min-w-56 rounded-xl border border-border bg-surface p-1 shadow-xl shadow-black/5',
              side === 'bottom' ? 'top-full mt-2' : 'bottom-full mb-2',
              align === 'end' ? 'right-0 origin-top-right' : 'left-0 origin-top-left',
              className,
            )}
          >
            {typeof children === 'function' ? children(close) : children}
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  )
}

export function MenuItem({ children, onClick, active, icon: Icon, danger }: {
  children: ReactNode; onClick?: () => void; active?: boolean
  icon?: React.ComponentType<{ className?: string; strokeWidth?: number }>; danger?: boolean
}) {
  return (
    <button role="menuitem" onClick={onClick}
            className={clsx('flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left text-sm transition-colors',
              danger ? 'text-danger hover:bg-danger/5' : 'text-fg hover:bg-muted', active && 'bg-muted')}>
      {Icon && <Icon className="size-4 shrink-0 text-fg-muted" strokeWidth={1.75} />}
      <span className="flex-1 truncate">{children}</span>
    </button>
  )
}

export const MenuSeparator = () => <div className="my-1 h-px bg-border" />
export const MenuLabel = ({ children }: { children: ReactNode }) => (
  <div className="px-2.5 pt-2 pb-1 text-[11px] font-medium uppercase tracking-wider text-fg-subtle">{children}</div>
)
