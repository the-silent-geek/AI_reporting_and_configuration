import clsx from 'clsx'
import { Check, Search, UserPlus, Users } from 'lucide-react'
import { motion } from 'motion/react'
import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import { Button } from '../../components/ui/Button'
import { Dialog } from '../../components/ui/Dialog'
import { Field, inputClass } from '../../components/ui/Field'
import { Avatar, Badge, Card, EmptyState, PageHeader, Skeleton } from '../../components/ui/Misc'
import { useToast } from '../../components/ui/Toast'
import { ApiError, api, json } from '../../lib/api'
import { useApp } from '../../lib/appContext'
import { useAuth } from '../../lib/auth'
import { fmtRelative } from '../../lib/format'
import type { AdminUser } from '../../lib/types'

const ROLES = [
  { code: 'APP_ADMIN', name: 'App admin', text: 'Everything in this app, including users and roles.' },
  { code: 'REVIEWER', name: 'Reviewer', text: 'Checker: approves batch commits and templates.' },
  { code: 'ANALYST', name: 'Analyst', text: 'Maker: uploads files, reviews mappings, fixes data.' },
  { code: 'VIEWER', name: 'Viewer', text: 'Reads dashboards and reports.' },
]

const errText = (e: unknown) => (e instanceof ApiError && typeof e.detail === 'string' ? e.detail : 'Something went wrong.')

export function AdminUsers() {
  const { app, code } = useApp()
  const { user: me } = useAuth()
  const toast = useToast()
  const [users, setUsers] = useState<AdminUser[] | null>(null)
  const [query, setQuery] = useState('')
  const [editing, setEditing] = useState<AdminUser | null>(null)
  const [creating, setCreating] = useState(false)

  const load = useCallback(async () => setUsers(await api<AdminUser[]>(`/api/apps/${code}/admin/users`)), [code])
  useEffect(() => { load().catch(() => setUsers([])) }, [load])

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase()
    return (users ?? []).filter((u) => !q || u.full_name.toLowerCase().includes(q) || u.email.toLowerCase().includes(q))
      .sort((a, b) => Number(b.roles.length > 0) - Number(a.roles.length > 0))   // members of this app first
  }, [users, query])

  return (
    <>
      <PageHeader title="Users & roles" description={`Who can access ${app.name}, and what they can do.`}
                  actions={<Button variant="primary" icon={UserPlus} onClick={() => setCreating(true)}>Add user</Button>} />

      <div className="relative mb-4 sm:w-72">
        <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-fg-subtle" />
        <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search name or email"
               aria-label="Search users" className={clsx(inputClass, 'h-9 pl-9')} />
      </div>

      <Card className="overflow-hidden">
        {!users ? <div className="space-y-3 p-5">{Array.from({ length: 5 }, (_, i) => <Skeleton key={i} className="h-11" />)}</div>
          : !shown.length ? <EmptyState icon={Users} title="No users found" /> : (
          <ul className="divide-y divide-border">
            {shown.map((u, i) => (
              <motion.li key={u.user_id} initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: Math.min(i, 10) * 0.02 }}
                         className="flex flex-col gap-3 px-4 py-3.5 sm:flex-row sm:items-center sm:gap-4 sm:px-5">
                <div className="flex min-w-0 flex-1 items-center gap-3">
                  <Avatar name={u.full_name} className={clsx(!u.is_active && 'opacity-40')} />
                  <div className="min-w-0">
                    <p className="flex items-center gap-2 truncate text-sm font-medium">
                      {u.full_name}
                      {u.user_id === me?.user_id && <span className="text-xs font-normal text-fg-subtle">(you)</span>}
                    </p>
                    <p className="truncate text-xs text-fg-muted">{u.email}</p>
                  </div>
                </div>
                <div className="flex flex-wrap items-center gap-1.5 sm:w-32 lg:w-48">
                  {u.is_super_admin && <Badge className="border-fg text-fg">Super admin</Badge>}
                  {u.roles.map((r) => <Badge key={r}>{r.replace('_', ' ')}</Badge>)}
                  {!u.roles.length && !u.is_super_admin && <span className="text-xs text-fg-subtle">No access</span>}
                </div>
                <div className="flex shrink-0 items-center justify-between gap-4 sm:justify-end">
                  <span className="text-xs text-fg-muted">
                    {!u.is_active ? <span className="text-danger">Disabled</span> : u.locked ? <span className="text-warning">Locked</span>
                      : u.last_login_at ? `Active ${fmtRelative(u.last_login_at)}` : 'Never signed in'}
                  </span>
                  <Button size="sm" onClick={() => setEditing(u)}>Manage</Button>
                </div>
              </motion.li>
            ))}
          </ul>
        )}
      </Card>

      <RolesDialog user={editing} onClose={() => setEditing(null)}
                   onSaved={(msg) => { toast({ tone: 'success', title: msg }); load() }}
                   onError={(e) => toast({ tone: 'error', title: 'Change refused', description: errText(e) })} />
      <CreateDialog open={creating} onClose={() => setCreating(false)}
                    onCreated={async (id, name) => {
                      setCreating(false)
                      toast({ tone: 'success', title: `${name} added`, description: 'Now choose their role.' })
                      const all = await api<AdminUser[]>(`/api/apps/${code}/admin/users`)
                      setUsers(all)
                      setEditing(all.find((u) => u.user_id === id) ?? null)
                    }} />
    </>
  )
}

function RolesDialog({ user, onClose, onSaved, onError }: {
  user: AdminUser | null; onClose: () => void; onSaved: (msg: string) => void; onError: (e: unknown) => void
}) {
  const { app, code } = useApp()
  const { user: me } = useAuth()
  const [selected, setSelected] = useState<string[]>([])
  const [busy, setBusy] = useState(false)
  useEffect(() => { if (user) setSelected(user.roles) }, [user])
  if (!user) return <Dialog open={false} onClose={onClose} title="" />

  const changed = selected.length !== user.roles.length || selected.some((r) => !user.roles.includes(r))

  async function save() {
    setBusy(true)
    try {
      for (const r of selected.filter((r) => !user!.roles.includes(r)))
        await api(`/api/apps/${code}/admin/users/${user!.user_id}/roles`, { method: 'POST', ...json({ role: r }) })
      for (const r of user!.roles.filter((r) => !selected.includes(r)))
        await api(`/api/apps/${code}/admin/users/${user!.user_id}/roles/${r}`, { method: 'DELETE' })
      onSaved(`Roles updated for ${user!.full_name}`)
      onClose()
    } catch (e) { onError(e) } finally { setBusy(false) }
  }

  async function setActive(active: boolean) {
    setBusy(true)
    try {
      await api(`/api/admin/users/${user!.user_id}`, { method: 'PATCH', ...json({ is_active: active }) })
      onSaved(`${user!.full_name} ${active ? 'enabled' : 'disabled'}`)
      onClose()
    } catch (e) { onError(e) } finally { setBusy(false) }
  }

  return (
    <Dialog open onClose={() => !busy && onClose()} title={user.full_name} description={`Roles in ${app.name} · ${user.email}`}
            footer={<>
              <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
              <Button variant="primary" onClick={save} loading={busy} disabled={!changed}>Save</Button>
            </>}>
      <div className="space-y-2">
        {ROLES.map((r) => {
          const on = selected.includes(r.code)
          return (
            <button key={r.code} type="button" role="checkbox" aria-checked={on}
                    onClick={() => setSelected((s) => (on ? s.filter((x) => x !== r.code) : [...s, r.code]))}
                    className={clsx('flex w-full items-start gap-3 rounded-lg border px-3.5 py-3 text-left transition-all duration-150',
                      on ? 'border-fg bg-subtle' : 'border-border hover:border-border-strong')}>
              <span className={clsx('mt-0.5 flex size-4 shrink-0 items-center justify-center rounded border transition-colors',
                on ? 'border-fg bg-fg text-bg' : 'border-border-strong')}>
                {on && <Check className="size-3" strokeWidth={3} />}
              </span>
              <span>
                <span className="block text-sm font-medium">{r.name}</span>
                <span className="block text-xs text-fg-muted">{r.text}</span>
              </span>
            </button>
          )
        })}
      </div>
      {me?.is_super_admin && me.user_id !== user.user_id && (
        <div className="mt-5 flex items-center justify-between rounded-lg border border-border px-3.5 py-3">
          <div>
            <p className="text-sm font-medium">{user.is_active ? 'Account active' : 'Account disabled'}</p>
            <p className="text-xs text-fg-muted">{user.is_active ? 'Disabling signs them out everywhere.' : 'Enabling also clears a lockout.'}</p>
          </div>
          <Button size="sm" variant={user.is_active ? 'danger' : 'secondary'} onClick={() => setActive(!user.is_active)} disabled={busy}>
            {user.is_active ? 'Disable' : 'Enable'}
          </Button>
        </div>
      )}
    </Dialog>
  )
}

function CreateDialog({ open, onClose, onCreated }: {
  open: boolean; onClose: () => void; onCreated: (id: string, name: string) => void
}) {
  const [form, setForm] = useState({ full_name: '', email: '', password: '' })
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  useEffect(() => { if (open) { setForm({ full_name: '', email: '', password: '' }); setError(null) } }, [open])

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true); setError(null)
    try {
      const r = await api<{ user_id: string }>('/api/admin/users', { method: 'POST', ...json(form) })
      onCreated(r.user_id, form.full_name)
    } catch (err) {
      setError(err instanceof ApiError && err.status === 409 ? 'A user with this email already exists.' : errText(err))
    } finally { setBusy(false) }
  }

  return (
    <Dialog open={open} onClose={() => !busy && onClose()} title="Add user" description="They can sign in once you give them a role.">
      <form onSubmit={submit} className="space-y-4">
        <Field label="Full name" required value={form.full_name} onChange={(e) => setForm({ ...form, full_name: e.target.value })} />
        <Field label="Work email" type="email" required value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
        <Field label="Temporary password" type="text" required minLength={8} autoComplete="new-password"
               hint="At least 8 characters with a letter and a digit. Share it securely."
               value={form.password} onChange={(e) => setForm({ ...form, password: e.target.value })} />
        {error && <p role="alert" className="text-sm text-danger">{error}</p>}
        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button type="submit" variant="primary" loading={busy}>Create user</Button>
        </div>
      </form>
    </Dialog>
  )
}
