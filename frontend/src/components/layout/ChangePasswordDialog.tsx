import { Check, Eye, EyeOff } from 'lucide-react'
import { useEffect, useState, type FormEvent } from 'react'
import { ApiError, api, json } from '../../lib/api'
import { Button } from '../ui/Button'
import { Dialog } from '../ui/Dialog'
import { Field } from '../ui/Field'
import { useToast } from '../ui/Toast'

const RULES = [
  { label: 'At least 8 characters', ok: (p: string) => p.length >= 8 },
  { label: 'A letter', ok: (p: string) => /[A-Za-z]/.test(p) },
  { label: 'A digit', ok: (p: string) => /\d/.test(p) },
]

function message(e: unknown) {
  if (e instanceof ApiError) {
    const d = e.detail as { status?: string } | string | undefined
    if (typeof d === 'object' && d?.status === 'INVALID_CREDENTIALS') return 'Current password is incorrect.'
    if (typeof d === 'string') return d
  }
  return 'Could not change the password. Please try again.'
}

/** Asks for the current password, then the new one twice. The server signs out all other devices. */
export function ChangePasswordDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const toast = useToast()
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const [confirm, setConfirm] = useState('')
  const [show, setShow] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (open) { setCurrent(''); setNext(''); setConfirm(''); setShow(false); setError(null) }
  }, [open])

  const valid = RULES.every((r) => r.ok(next))
  const mismatch = confirm.length > 0 && confirm !== next
  const same = next.length > 0 && next === current
  const canSubmit = !!current && valid && next === confirm && !same

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (!canSubmit) return
    setBusy(true); setError(null)
    try {
      await api('/api/auth/change-password', { method: 'POST', ...json({ old_password: current, new_password: next }) })
      toast({ tone: 'success', title: 'Password updated', description: 'You were signed out on your other devices.' })
      onClose()
    } catch (err) {
      setError(message(err))
    } finally {
      setBusy(false)
    }
  }

  const eye = (
    <button type="button" onClick={() => setShow((s) => !s)} aria-label={show ? 'Hide passwords' : 'Show passwords'}
            className="rounded-md p-2 text-fg-subtle transition-colors hover:text-fg">
      {show ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
    </button>
  )
  const type = show ? 'text' : 'password'

  return (
    <Dialog open={open} onClose={() => !busy && onClose()} title="Change password"
            description="Enter your current password to set a new one.">
      <form onSubmit={submit} className="space-y-4" noValidate>
        <Field label="Current password" type={type} autoComplete="current-password" required trailing={eye}
               value={current} onChange={(e) => setCurrent(e.target.value)} />
        <Field label="New password" type={type} autoComplete="new-password" required
               error={same ? 'New password must differ from the current one.' : null}
               value={next} onChange={(e) => setNext(e.target.value)} />
        <ul className="flex flex-wrap gap-x-4 gap-y-1 text-xs">
          {RULES.map((r) => {
            const ok = r.ok(next)
            return (
              <li key={r.label} className={ok ? 'text-success' : 'text-fg-muted'}>
                <span className="inline-flex items-center gap-1">
                  <Check className={ok ? 'size-3' : 'size-3 opacity-30'} strokeWidth={3} />{r.label}
                </span>
              </li>
            )
          })}
        </ul>
        <Field label="Confirm new password" type={type} autoComplete="new-password" required
               error={mismatch ? 'Passwords do not match.' : null}
               value={confirm} onChange={(e) => setConfirm(e.target.value)} />
        {error && <p role="alert" className="text-sm text-danger">{error}</p>}
        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button type="submit" variant="primary" loading={busy} disabled={!canSubmit}>Update password</Button>
        </div>
      </form>
    </Dialog>
  )
}
