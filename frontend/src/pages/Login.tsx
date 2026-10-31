import { AlertCircle, Eye, EyeOff, Fingerprint, LineChart, ShieldCheck } from 'lucide-react'
import { AnimatePresence, motion } from 'motion/react'
import { useState, type FormEvent } from 'react'
import { Navigate, useLocation, useNavigate } from 'react-router-dom'
import { Button } from '../components/ui/Button'
import { Field } from '../components/ui/Field'
import { Brand } from '../components/ui/Misc'
import { ApiError } from '../lib/api'
import { useAuth } from '../lib/auth'

const POINTS = [
  { icon: LineChart, title: 'Every number traceable', text: 'Drill from any KPI to the exact file and row it came from.' },
  { icon: ShieldCheck, title: 'Role-based by design', text: 'Each product shows only what your role allows.' },
  { icon: Fingerprint, title: 'One sign-in', text: 'ERP, AML and Lending behind a single secure session.' },
]

function message(e: unknown) {
  if (!(e instanceof ApiError)) return 'Could not reach the server. Check your connection.'
  const d = e.detail as { status?: string; locked_until?: string } | undefined
  switch (d?.status) {
    case 'ACCOUNT_LOCKED': {
      const until = d.locked_until ? new Date(d.locked_until).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : null
      return `Too many failed attempts. Try again${until ? ` after ${until}` : ' later'}.`
    }
    case 'ACCOUNT_DISABLED': return 'This account is disabled. Contact your administrator.'
    case 'INVALID_CREDENTIALS': return 'Incorrect email or password.'
    default: return e.status === 422 ? 'Enter a valid email and password.' : 'Sign-in failed. Please try again.'
  }
}

export function Login() {
  const { status, login } = useAuth()
  const navigate = useNavigate()
  const from = (useLocation().state as { from?: string } | null)?.from ?? '/'
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [show, setShow] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (status === 'authenticated') return <Navigate to={from} replace />

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true); setError(null)
    try {
      await login(email.trim(), password)
      navigate(from, { replace: true })
    } catch (err) {
      setError(message(err))
      setPassword('')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="grid min-h-full lg:grid-cols-[1.05fr_1fr]">
      {/* Brand panel (desktop) */}
      {/* Always dark (black in light theme, elevated charcoal in dark theme) - never a white half-screen. */}
      <aside className="relative hidden overflow-hidden border-border bg-zinc-950 text-white lg:flex lg:flex-col lg:justify-between lg:p-12 dark:border-r dark:bg-subtle dark:text-fg">
        <div aria-hidden className="absolute inset-0 opacity-[0.07]"
             style={{ backgroundImage: 'radial-gradient(currentColor 1px, transparent 1px)', backgroundSize: '22px 22px',
                      maskImage: 'radial-gradient(ellipse at 30% 40%, black 30%, transparent 75%)' }} />
        <Brand inverted />
        <div className="relative max-w-md">
          <motion.h2 initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
                     className="text-3xl leading-tight font-semibold tracking-tight xl:text-4xl">
            Verified reporting for ERP, AML and Lending.
          </motion.h2>
          <ul className="mt-10 space-y-6">
            {POINTS.map((p, i) => (
              <motion.li key={p.title} className="flex gap-4"
                         initial={{ opacity: 0, x: -10 }} animate={{ opacity: 1, x: 0 }}
                         transition={{ delay: 0.15 + i * 0.08, duration: 0.5, ease: [0.22, 1, 0.36, 1] }}>
                <span className="flex size-9 shrink-0 items-center justify-center rounded-lg border border-white/15 dark:border-border">
                  <p.icon className="size-4" strokeWidth={1.75} />
                </span>
                <span>
                  <span className="block text-sm font-medium">{p.title}</span>
                  <span className="block text-sm opacity-60">{p.text}</span>
                </span>
              </motion.li>
            ))}
          </ul>
        </div>
        <p className="relative text-xs opacity-40">© {new Date().getFullYear()} Reporting Studio</p>
      </aside>

      {/* Form */}
      <main className="flex items-center justify-center px-6 py-12">
        <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }}
                    transition={{ duration: 0.4, ease: [0.22, 1, 0.36, 1] }} className="w-full max-w-sm">
          <div className="mb-10 lg:hidden"><Brand /></div>
          <h1 className="text-2xl font-semibold tracking-tight">Sign in</h1>
          <p className="mt-1.5 text-sm text-fg-muted">Use your work account to continue.</p>

          <form onSubmit={submit} className="mt-8 space-y-4" noValidate>
            <AnimatePresence initial={false}>
              {error && (
                <motion.div role="alert" initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }}
                            exit={{ opacity: 0, height: 0 }} className="overflow-hidden">
                  <div className="flex items-start gap-2.5 rounded-lg border border-danger/25 bg-danger/5 px-3 py-2.5 text-sm text-danger">
                    <AlertCircle className="mt-0.5 size-4 shrink-0" />{error}
                  </div>
                </motion.div>
              )}
            </AnimatePresence>
            <Field label="Email" type="email" autoComplete="username" required autoFocus
                   value={email} onChange={(e) => setEmail(e.target.value)} placeholder="name@company.com" />
            <Field label="Password" type={show ? 'text' : 'password'} autoComplete="current-password" required
                   value={password} onChange={(e) => setPassword(e.target.value)}
                   trailing={
                     <button type="button" onClick={() => setShow((s) => !s)} aria-label={show ? 'Hide password' : 'Show password'}
                             className="rounded-md p-2 text-fg-subtle transition-colors hover:text-fg">
                       {show ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
                     </button>
                   } />
            <Button type="submit" variant="primary" loading={busy} disabled={!email || !password} className="mt-2 h-10 w-full justify-center">
              {busy ? 'Signing in…' : 'Sign in'}
            </Button>
          </form>
          <p className="mt-8 text-xs text-fg-subtle">
            Accounts are created by your administrator. After 5 failed attempts an account is locked for 15 minutes.
          </p>
        </motion.div>
      </main>
    </div>
  )
}
