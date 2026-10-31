import { ChevronsUpDown, LayoutGrid } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { useApp } from '../../lib/appContext'
import { useAuth } from '../../lib/auth'
import { iconFor } from '../../lib/icons'
import { Menu, MenuItem, MenuLabel, MenuSeparator } from '../ui/Menu'

/** Header control to jump between the applications the user has a role in. */
export function AppSwitcher() {
  const { app } = useApp()
  const { apps } = useAuth()
  const navigate = useNavigate()
  const Icon = iconFor(app.icon)

  return (
    <Menu align="start" className="w-60" trigger={({ toggle, open }) => (
      <button onClick={toggle} aria-expanded={open} aria-label={`Current application: ${app.name}. Switch application`}
              className="flex h-9 items-center gap-2 rounded-lg border border-border bg-surface pr-2 pl-1.5 text-sm font-medium shadow-sm transition-colors hover:border-border-strong">
        <span className="flex size-6 shrink-0 items-center justify-center rounded-md bg-fg text-bg">
          <Icon className="size-3.5" strokeWidth={2} />
        </span>
        <span className="max-w-28 truncate sm:max-w-none">{app.name}</span>
        <ChevronsUpDown className="size-3.5 text-fg-subtle" />
      </button>
    )}>
      {(close) => (
        <>
          <MenuLabel>Switch application</MenuLabel>
          {apps.map((a) => (
            <MenuItem key={a.code} icon={iconFor(a.icon)} active={a.code === app.code}
                      onClick={() => { close(); if (a.code !== app.code) navigate(a.route) }}>
              {a.name}
            </MenuItem>
          ))}
          <MenuSeparator />
          <MenuItem icon={LayoutGrid} onClick={() => { close(); navigate('/') }}>All applications</MenuItem>
        </>
      )}
    </Menu>
  )
}
