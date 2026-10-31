/* The app the user is inside (ERP / AML / LENDING): roles, permissions, sidebar.
   Loaded from POST /api/apps/{code}/select when entering /app/{code}. */
import { createContext, useContext } from 'react'
import type { AppContext as Ctx, MenuItem } from './types'

export interface AppState extends Ctx {
  code: string                       // lower-case, as used in API paths
  can: (permission: string) => boolean
}

export const AppCtx = createContext<AppState | null>(null)

export function useApp() {
  const ctx = useContext(AppCtx)
  if (!ctx) throw new Error('useApp outside AppShell')
  return ctx
}

/** Every route the shell knows. The longest one matching the URL decides the
    permission (via the sidebar the server returned for this user). */
export const KNOWN_ROUTES = ['/dashboard', '/datasets', '/datasets/upload', '/mapping', '/data-quality',
  '/reports', '/templates', '/assistant', '/admin', '/admin/users']

export function flatten(items: MenuItem[]): MenuItem[] {
  return items.flatMap((i) => [i, ...flatten(i.children ?? [])])
}

/** Is `subPath` (path after /app/{code}) visible to this user? Backend enforces too. */
export function isAllowed(subPath: string, sidebar: MenuItem[]) {
  const route = KNOWN_ROUTES.filter((r) => subPath === r || subPath.startsWith(r + '/'))
    .sort((a, b) => b.length - a.length)[0]
  if (!route) return true                                  // unknown -> NotFound handles it
  return flatten(sidebar).some((m) => m.route === route)
}

/** Label of the deepest sidebar item matching the URL (for breadcrumbs). */
export function currentLabel(subPath: string, sidebar: MenuItem[]) {
  return flatten(sidebar)
    .filter((m) => subPath === m.route || subPath.startsWith(m.route + '/'))
    .sort((a, b) => b.route.length - a.route.length)[0]?.label
}
