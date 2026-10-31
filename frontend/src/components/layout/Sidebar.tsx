import clsx from 'clsx'
import { ChevronDown, ChevronsUpDown, LayoutGrid, PanelLeftClose, PanelLeftOpen } from 'lucide-react'
import { AnimatePresence, motion } from 'motion/react'
import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { Link, NavLink, useLocation, useNavigate } from 'react-router-dom'
import { useApp } from '../../lib/appContext'
import { useAuth } from '../../lib/auth'
import { iconFor } from '../../lib/icons'
import type { MenuItem as Item } from '../../lib/types'
import { Brand } from '../ui/Misc'
import { Menu, MenuItem, MenuLabel, MenuSeparator } from '../ui/Menu'

export const SIDEBAR_EXPANDED = 256
export const SIDEBAR_COLLAPSED = 72
const spring = { type: 'spring', stiffness: 320, damping: 34 } as const

/** Sidebar content. Used inline on desktop (collapsible) and inside the mobile drawer (always expanded). */
export function Sidebar({ collapsed, onToggle, onNavigate }: {
  collapsed: boolean
  onToggle?: () => void
  onNavigate?: () => void
}) {
  const { sidebar, app } = useApp()
  const base = app.route    // e.g. /app/erp

  return (
    <div className="flex h-full flex-col">
      <div className={clsx('flex h-14 shrink-0 items-center', collapsed ? 'justify-center px-0' : 'px-5')}>
        <Link to="/" aria-label="All applications" onClick={onNavigate}><Brand compact={collapsed} /></Link>
      </div>

      <div className={clsx('pb-3', collapsed ? 'px-3' : 'px-3')}>
        <AppSwitcher collapsed={collapsed} onNavigate={onNavigate} />
      </div>

      <nav aria-label="Main" className="flex-1 space-y-0.5 overflow-y-auto overflow-x-hidden px-3 py-2">
        {sidebar.map((item) => (
          <NavEntry key={item.code} item={item} base={base} collapsed={collapsed} onNavigate={onNavigate} />
        ))}
      </nav>

      {onToggle && (
        <div className="shrink-0 border-t border-border p-3">
          <button onClick={onToggle}
                  aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
                  title={`${collapsed ? 'Expand' : 'Collapse'} sidebar (Ctrl+B)`}
                  className={clsx('flex h-9 w-full items-center gap-3 rounded-lg px-3 text-sm text-fg-muted transition-colors hover:bg-muted hover:text-fg',
                    collapsed && 'justify-center px-0')}>
            {collapsed ? <PanelLeftOpen className="size-4" strokeWidth={1.75} /> : <PanelLeftClose className="size-4" strokeWidth={1.75} />}
            <Label show={!collapsed}>Collapse</Label>
            {!collapsed && <kbd className="ml-auto rounded border border-border px-1.5 text-[10px] text-fg-subtle">Ctrl B</kbd>}
          </button>
        </div>
      )}
    </div>
  )
}

/** Text that fades/slides out as the sidebar collapses. */
function Label({ show, children }: { show: boolean; children: React.ReactNode }) {
  return (
    <AnimatePresence initial={false}>
      {show && (
        <motion.span initial={{ opacity: 0, x: -6 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: -6 }}
                     transition={{ duration: 0.18 }} className="truncate whitespace-nowrap">
          {children}
        </motion.span>
      )}
    </AnimatePresence>
  )
}

function NavEntry({ item, base, collapsed, onNavigate }: {
  item: Item; base: string; collapsed: boolean; onNavigate?: () => void
}) {
  const { pathname } = useLocation()
  const to = base + item.route
  const children = item.children ?? []
  const within = pathname === to || pathname.startsWith(to + '/')
  const [open, setOpen] = useState(within)
  const [tip, setTip] = useState<DOMRect | null>(null)
  useEffect(() => { if (within) setOpen(true) }, [within])
  useEffect(() => { if (!collapsed) setTip(null) }, [collapsed])
  const Icon = iconFor(item.icon)

  // A parent is "active" only when no child is the better match.
  const childActive = children.some((c) => pathname === base + c.route || pathname.startsWith(base + c.route + '/'))
  const active = within && !(open && !collapsed && childActive && children.length)

  return (
    <div>
      <div className="group relative">
        <NavLink
          to={to}
          end={!children.length}
          onMouseEnter={(e) => collapsed && setTip(e.currentTarget.getBoundingClientRect())}
          onMouseLeave={() => setTip(null)}
          onFocus={(e) => collapsed && setTip(e.currentTarget.getBoundingClientRect())}
          onBlur={() => setTip(null)}
          onClick={(e) => {
            if (children.length && !collapsed) { e.preventDefault(); setOpen((o) => !o); return }
            onNavigate?.()
          }}
          className={clsx('relative flex h-9 items-center gap-3 rounded-lg px-3 text-sm transition-colors duration-150',
            collapsed && 'justify-center px-0',
            active ? 'font-medium text-fg' : 'text-fg-muted hover:text-fg hover:bg-muted/60')}
          aria-current={active ? 'page' : undefined}
        >
          {active && (
            <motion.span layoutId="nav-active" transition={spring}
                         className="absolute inset-0 rounded-lg border border-border bg-surface shadow-sm" />
          )}
          <Icon className="relative size-4 shrink-0" strokeWidth={1.75} />
          {!collapsed && <span className="relative flex-1 truncate">{item.label}</span>}
          {!collapsed && children.length > 0 && (
            <motion.span animate={{ rotate: open ? 0 : -90 }} transition={{ duration: 0.2 }} className="relative">
              <ChevronDown className="size-3.5 text-fg-subtle" />
            </motion.span>
          )}
        </NavLink>
        {collapsed && <Tooltip rect={tip}>{item.label}</Tooltip>}
      </div>

      <AnimatePresence initial={false}>
        {!collapsed && open && children.length > 0 && (
          <motion.div initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }}
                      exit={{ height: 0, opacity: 0 }} transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
                      className="overflow-hidden">
            <div className="relative ml-[1.35rem] space-y-0.5 border-l border-border py-1 pl-3">
              {children.map((c) => {
                const ChildIcon = iconFor(c.icon)
                return (
                  <NavLink key={c.code} to={base + c.route} end onClick={onNavigate}
                    className={({ isActive }) => clsx('relative flex h-8 items-center gap-2.5 rounded-md px-2.5 text-[13px] transition-colors',
                      isActive ? 'font-medium text-fg' : 'text-fg-muted hover:bg-muted/60 hover:text-fg')}>
                    {({ isActive }) => (
                      <>
                        {isActive && <motion.span layoutId="nav-active" transition={spring}
                                                  className="absolute inset-0 rounded-md border border-border bg-surface shadow-sm" />}
                        <ChildIcon className="relative size-3.5" strokeWidth={1.75} />
                        <span className="relative truncate">{c.label}</span>
                      </>
                    )}
                  </NavLink>
                )
              })}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  )
}

/** Label shown to the right of an icon in the collapsed rail. Portalled with fixed
    position so the nav's scroll container can't clip it. */
function Tooltip({ rect, children }: { rect: DOMRect | null; children: React.ReactNode }) {
  return createPortal(
    <AnimatePresence>
      {rect && (
        <motion.span role="tooltip" initial={{ opacity: 0, x: -4 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: -4 }}
                     transition={{ duration: 0.12 }} style={{ top: rect.top + rect.height / 2, left: rect.right + 12 }}
                     className="pointer-events-none fixed z-[70] -translate-y-1/2 rounded-md bg-fg px-2 py-1 text-xs font-medium whitespace-nowrap text-bg shadow-lg">
          {children}
        </motion.span>
      )}
    </AnimatePresence>,
    document.body,
  )
}

function AppSwitcher({ collapsed, onNavigate }: { collapsed: boolean; onNavigate?: () => void }) {
  const { app } = useApp()
  const { apps } = useAuth()
  const navigate = useNavigate()
  const Icon = iconFor(app.icon)

  return (
    <Menu align="start" className="w-60" trigger={({ toggle, open }) => (
      <button onClick={toggle} aria-expanded={open} aria-label={`Current app: ${app.name}. Switch app`}
              className={clsx('flex h-11 w-full items-center gap-3 rounded-lg border border-border bg-surface px-2.5 text-left shadow-sm transition-colors hover:border-border-strong',
                collapsed && 'justify-center px-0')}>
        <span className="flex size-7 shrink-0 items-center justify-center rounded-md bg-fg text-bg">
          <Icon className="size-3.5" strokeWidth={2} />
        </span>
        {!collapsed && (
          <>
            <span className="min-w-0 flex-1">
              <span className="block text-[11px] leading-tight text-fg-subtle">Application</span>
              <span className="block truncate text-sm font-medium leading-tight">{app.name}</span>
            </span>
            <ChevronsUpDown className="size-3.5 text-fg-subtle" />
          </>
        )}
      </button>
    )}>
      {(close) => (
        <>
          <MenuLabel>Switch application</MenuLabel>
          {apps.map((a) => (
            <MenuItem key={a.code} icon={iconFor(a.icon)} active={a.code === app.code}
                      onClick={() => { close(); onNavigate?.(); navigate(a.route) }}>
              {a.name}
            </MenuItem>
          ))}
          <MenuSeparator />
          <MenuItem icon={LayoutGrid} onClick={() => { close(); onNavigate?.(); navigate('/') }}>All applications</MenuItem>
        </>
      )}
    </Menu>
  )
}
