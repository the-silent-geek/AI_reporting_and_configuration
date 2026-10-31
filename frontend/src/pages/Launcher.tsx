import { ArrowUpRight, LayoutGrid } from 'lucide-react'
import { motion } from 'motion/react'
import { Link } from 'react-router-dom'
import { ThemeToggle } from '../components/layout/ThemeToggle'
import { UserMenu } from '../components/layout/UserMenu'
import { Badge, Brand, EmptyState } from '../components/ui/Misc'
import { useAuth } from '../lib/auth'
import { greeting } from '../lib/format'
import { iconFor } from '../lib/icons'

/** SSO landing: one card per application the user has a role in. */
export function Launcher() {
  const { user, apps } = useAuth()
  const first = user?.full_name.split(' ')[0]

  return (
    <div className="min-h-full">
      <header className="sticky top-0 z-30 border-b border-border bg-bg/80 backdrop-blur-md">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 sm:px-6">
          <Brand />
          <div className="flex items-center gap-1">
            <ThemeToggle />
            <UserMenu />
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-4 py-10 sm:px-6 sm:py-16">
        <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.4 }}>
          <p className="text-sm text-fg-muted">{greeting()}{first ? `, ${first}` : ''}</p>
          <h1 className="mt-1 text-2xl font-semibold tracking-tight sm:text-3xl">Choose an application</h1>
        </motion.div>

        {apps.length === 0 ? (
          <EmptyState icon={LayoutGrid} title="No applications assigned yet">
            Ask your administrator to give you a role in ERP, AML or Lending.
          </EmptyState>
        ) : (
          <motion.ul className="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
                     initial="hidden" animate="show"
                     variants={{ show: { transition: { staggerChildren: 0.07, delayChildren: 0.1 } } }}>
            {apps.map((app) => {
              const Icon = iconFor(app.icon)
              return (
                <motion.li key={app.code}
                           variants={{ hidden: { opacity: 0, y: 14 }, show: { opacity: 1, y: 0, transition: { duration: 0.45, ease: [0.22, 1, 0.36, 1] } } }}>
                  <Link to={app.route}
                        className="group relative flex h-full flex-col rounded-2xl border border-border bg-surface p-6 transition-all duration-300 ease-out-soft hover:-translate-y-0.5 hover:border-border-strong hover:shadow-xl hover:shadow-black/[0.04] focus-visible:-translate-y-0.5">
                    <div className="flex items-start justify-between">
                      <span className="flex size-11 items-center justify-center rounded-xl bg-fg text-bg transition-transform duration-300 group-hover:scale-105">
                        <Icon className="size-5" strokeWidth={1.75} />
                      </span>
                      <ArrowUpRight className="size-4 text-fg-subtle transition-all duration-300 group-hover:translate-x-0.5 group-hover:-translate-y-0.5 group-hover:text-fg" />
                    </div>
                    <h2 className="mt-6 text-lg font-semibold tracking-tight">{app.name}</h2>
                    <p className="mt-1 flex-1 text-sm text-fg-muted">{app.description}</p>
                    <div className="mt-6 flex flex-wrap gap-1.5">
                      {user?.is_super_admin && !app.roles.length
                        ? <Badge>Super admin</Badge>
                        : app.roles.map((r) => <Badge key={r}>{r.replace('_', ' ')}</Badge>)}
                    </div>
                  </Link>
                </motion.li>
              )
            })}
          </motion.ul>
        )}
      </main>
    </div>
  )
}
