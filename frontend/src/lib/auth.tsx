/* Session state for the whole UI.

   On load: try a silent refresh (httpOnly cookie) -> logged in without a form.
   Exposes the user, their dashboard cards (apps), login and logout. */
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { ApiError, api, json, onSessionEnded, refreshSession, setAccessToken } from './api'
import type { AppCard, User } from './types'

type Status = 'loading' | 'authenticated' | 'anonymous'

interface AuthState {
  status: Status
  user: User | null
  apps: AppCard[]
  login: (email: string, password: string) => Promise<void>
  logout: () => Promise<void>
  reloadApps: () => Promise<void>
}

const AuthContext = createContext<AuthState | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<Status>('loading')
  const [user, setUser] = useState<User | null>(null)
  const [apps, setApps] = useState<AppCard[]>([])

  const clear = useCallback(() => {
    setAccessToken(null)
    setUser(null)
    setApps([])
    setStatus('anonymous')
  }, [])

  const reloadApps = useCallback(async () => setApps(await api<AppCard[]>('/api/apps')), [])

  useEffect(() => {
    onSessionEnded(clear)
    let cancelled = false
    refreshSession().then(async (r) => {
      if (cancelled) return
      if (!r) return clear()
      setUser(r.user)
      try {
        setApps(await api<AppCard[]>('/api/apps'))
        setStatus('authenticated')
      } catch {
        clear()
      }
    })
    return () => { cancelled = true }
  }, [clear])

  const login = useCallback(async (email: string, password: string) => {
    const r = await api<{ access_token: string; user: User; apps: AppCard[] }>(
      '/api/auth/login', { method: 'POST', ...json({ email, password }) })
    setAccessToken(r.access_token)
    setUser(r.user)
    setApps(r.apps)
    setStatus('authenticated')
  }, [])

  const logout = useCallback(async () => {
    try { await api('/api/auth/logout', { method: 'POST' }) } catch (e) { if (!(e instanceof ApiError)) throw e }
    clear()
  }, [clear])

  const value = useMemo(() => ({ status, user, apps, login, logout, reloadApps }),
    [status, user, apps, login, logout, reloadApps])
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth outside AuthProvider')
  return ctx
}
