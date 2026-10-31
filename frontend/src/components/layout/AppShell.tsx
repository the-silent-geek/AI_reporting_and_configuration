import { ChevronRight, Lock, Menu as MenuIcon, X } from 'lucide-react'
import { AnimatePresence, motion } from 'motion/react'
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link, Navigate, Outlet, useLocation, useParams } from 'react-router-dom'
import { ApiError, api } from '../../lib/api'
import { AppCtx, currentLabel, isAllowed, type AppState } from '../../lib/appContext'
import type { AppContext } from '../../lib/types'
import { Button } from '../ui/Button'
import { EmptyState, Skeleton } from '../ui/Misc'
import { Sidebar, SIDEBAR_COLLAPSED, SIDEBAR_EXPANDED } from './Sidebar'
import { UserMenu } from './UserMenu'

const COLLAPSE_KEY = 'sidebar-collapsed'

export function AppShell() {
  const { appCode = '' } = useParams()
  const code = appCode.toLowerCase()
  const { pathname } = useLocation()
  const [ctx, setCtx] = useState<AppContext | null>(null)
  const [error, setError] = useState<number | null>(null)
  const [collapsed, setCollapsed] = useState(() => {
    try { return localStorage.getItem(COLLAPSE_KEY) === '1' } catch { return false }
  })
  const [drawer, setDrawer] = useState(false)

  // Enter the app: server returns this user's roles, permissions and sidebar.
  useEffect(() => {
    let cancelled = false
    setCtx(null); setError(null)
    api<AppContext>(`/api/apps/${code}/select`, { method: 'POST' })
      .then((c) => !cancelled && setCtx(c))
      .catch((e) => !cancelled && setError(e instanceof ApiError ? e.status : 500))
    return () => { cancelled = true }
  }, [code])

  const toggle = useCallback(() => setCollapsed((c) => {
    try { localStorage.setItem(COLLAPSE_KEY, c ? '0' : '1') } catch { /* ignore */ }
    return !c
  }), [])

  // Ctrl/Cmd + B toggles the sidebar (like most editors).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'b') { e.preventDefault(); toggle() }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [toggle])

  useEffect(() => setDrawer(false), [pathname])

  const state = useMemo<AppState | null>(() => ctx && {
    ...ctx, code,
    can: (p: string) => ctx.permissions.includes(p),
  }, [ctx, code])

  if (error) {
    return (
      <div className="flex min-h-full items-center justify-center p-6">
        <EmptyState icon={Lock} title={error === 403 ? 'No access to this application' : 'Application not available'}
                    action={<Link to="/"><Button>Back to applications</Button></Link>}>
          {error === 403 ? 'Ask an administrator to assign you a role in this application.' : 'Please try again.'}
        </EmptyState>
      </div>
    )
  }
  if (!state) return <ShellSkeleton collapsed={collapsed} />

  const sub = pathname.slice(state.app.route.length) || '/'
  if (sub === '/' || sub === '') return <Navigate to={`${state.app.route}/dashboard`} replace />
  const allowed = isAllowed(sub, state.sidebar)
  const page = currentLabel(sub, state.sidebar)

  return (
    <AppCtx.Provider value={state}>
      <div className="flex h-full">
        {/* Desktop sidebar: animated width */}
        <motion.aside
          initial={false}
          animate={{ width: collapsed ? SIDEBAR_COLLAPSED : SIDEBAR_EXPANDED }}
          transition={{ type: 'spring', stiffness: 320, damping: 34 }}
          className="hidden shrink-0 border-r border-border bg-subtle lg:block"
        >
          <Sidebar collapsed={collapsed} onToggle={toggle} />
        </motion.aside>

        {/* Mobile / tablet drawer */}
        <AnimatePresence>
          {drawer && (
            <div className="fixed inset-0 z-40 lg:hidden">
              <motion.div className="absolute inset-0 bg-black/40" onClick={() => setDrawer(false)}
                          initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} />
              <motion.aside
                className="absolute inset-y-0 left-0 w-[min(18rem,85vw)] border-r border-border bg-subtle shadow-2xl"
                initial={{ x: '-100%' }} animate={{ x: 0 }} exit={{ x: '-100%' }}
                transition={{ type: 'spring', stiffness: 380, damping: 38 }}
              >
                <button onClick={() => setDrawer(false)} aria-label="Close menu"
                        className="absolute top-3 right-3 z-10 rounded-md p-2 text-fg-muted hover:bg-muted hover:text-fg">
                  <X className="size-4" />
                </button>
                <Sidebar collapsed={false} onNavigate={() => setDrawer(false)} />
              </motion.aside>
            </div>
          )}
        </AnimatePresence>

        <div className="flex min-w-0 flex-1 flex-col">
          <header className="sticky top-0 z-30 flex h-14 shrink-0 items-center gap-3 border-b border-border bg-bg/80 px-4 backdrop-blur-md sm:px-6">
            <button onClick={() => setDrawer(true)} aria-label="Open menu"
                    className="-ml-1 rounded-md p-2 text-fg-muted hover:bg-muted hover:text-fg lg:hidden">
              <MenuIcon className="size-5" strokeWidth={1.75} />
            </button>
            <nav aria-label="Breadcrumb" className="flex min-w-0 items-center gap-1.5 text-sm">
              <Link to={`${state.app.route}/dashboard`} className="text-fg-muted transition-colors hover:text-fg">{state.app.name}</Link>
              {page && <>
                <ChevronRight className="size-3.5 shrink-0 text-fg-subtle" />
                <span className="truncate font-medium">{page}</span>
              </>}
            </nav>
            <div className="ml-auto"><UserMenu roles={state.roles} /></div>
          </header>

          <main className="flex-1 overflow-y-auto">
            <motion.div key={pathname} initial={{ opacity: 0, y: 6 }} animate={{ opacity: 1, y: 0 }}
                        transition={{ duration: 0.25, ease: [0.22, 1, 0.36, 1] }}
                        className="mx-auto w-full max-w-7xl px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
              {allowed ? <Outlet /> : (
                <EmptyState icon={Lock} title="You don't have access to this page"
                            action={<Link to={`${state.app.route}/dashboard`}><Button>Go to dashboard</Button></Link>}>
                  Your role in {state.app.name} doesn't include it.
                </EmptyState>
              )}
            </motion.div>
          </main>
        </div>
      </div>
    </AppCtx.Provider>
  )
}

function ShellSkeleton({ collapsed }: { collapsed: boolean }) {
  return (
    <div className="flex h-full">
      <div className="hidden shrink-0 border-r border-border bg-subtle p-3 lg:block"
           style={{ width: collapsed ? SIDEBAR_COLLAPSED : SIDEBAR_EXPANDED }}>
        <Skeleton className="mb-4 h-8 w-32" />
        <Skeleton className="mb-6 h-11 w-full" />
        {Array.from({ length: 7 }, (_, i) => <Skeleton key={i} className="mb-2 h-8 w-full" />)}
      </div>
      <div className="flex-1">
        <div className="h-14 border-b border-border" />
        <div className="mx-auto max-w-7xl space-y-4 p-8">
          <Skeleton className="h-7 w-48" />
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {Array.from({ length: 4 }, (_, i) => <Skeleton key={i} className="h-24" />)}
          </div>
          <Skeleton className="h-64" />
        </div>
      </div>
    </div>
  )
}
