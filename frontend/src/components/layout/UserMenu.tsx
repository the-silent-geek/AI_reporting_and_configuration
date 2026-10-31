import { Check, LogOut, Monitor, Moon, Sun } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../../lib/auth'
import { useTheme, type Theme } from '../../lib/theme'
import { Avatar } from '../ui/Misc'
import { Menu, MenuItem, MenuLabel, MenuSeparator } from '../ui/Menu'

const THEMES: { value: Theme; label: string; icon: typeof Sun }[] = [
  { value: 'light', label: 'Light', icon: Sun },
  { value: 'dark', label: 'Dark', icon: Moon },
  { value: 'system', label: 'System', icon: Monitor },
]

export function UserMenu({ roles }: { roles?: string[] }) {
  const { user, logout } = useAuth()
  const { theme, setTheme } = useTheme()
  const navigate = useNavigate()
  if (!user) return null

  return (
    <Menu trigger={({ toggle, open }) => (
      <button onClick={toggle} aria-expanded={open} aria-label="Account menu"
              className="flex items-center gap-2 rounded-full p-0.5 transition-shadow hover:ring-4 hover:ring-muted">
        <Avatar name={user.full_name} />
      </button>
    )}>
      {(close) => (
        <>
          <div className="px-2.5 py-2">
            <p className="truncate text-sm font-medium">{user.full_name}</p>
            <p className="truncate text-xs text-fg-muted">{user.email}</p>
            {(user.is_super_admin || roles?.length) ? (
              <p className="mt-1.5 text-[11px] font-medium uppercase tracking-wide text-fg-subtle">
                {user.is_super_admin ? 'Super admin' : roles!.map((r) => r.replace('_', ' ')).join(' · ')}
              </p>
            ) : null}
          </div>
          <MenuSeparator />
          <MenuLabel>Theme</MenuLabel>
          {THEMES.map((t) => (
            <MenuItem key={t.value} icon={t.icon} onClick={() => setTheme(t.value)}>
              <span className="flex items-center justify-between">
                {t.label}{theme === t.value && <Check className="size-3.5" />}
              </span>
            </MenuItem>
          ))}
          <MenuSeparator />
          <MenuItem icon={LogOut} onClick={async () => { close(); await logout(); navigate('/login') }}>
            Sign out
          </MenuItem>
        </>
      )}
    </Menu>
  )
}
