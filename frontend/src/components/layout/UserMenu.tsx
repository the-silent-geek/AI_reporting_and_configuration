import { KeyRound, LogOut } from 'lucide-react'
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../../lib/auth'
import { Avatar } from '../ui/Misc'
import { Menu, MenuItem, MenuSeparator } from '../ui/Menu'
import { ChangePasswordDialog } from './ChangePasswordDialog'

export function UserMenu({ roles }: { roles?: string[] }) {
  const { user, logout } = useAuth()
  const navigate = useNavigate()
  const [changing, setChanging] = useState(false)
  if (!user) return null

  return (
    <>
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
            <MenuItem icon={KeyRound} onClick={() => { close(); setChanging(true) }}>Change password</MenuItem>
            <MenuItem icon={LogOut} onClick={async () => { close(); await logout(); navigate('/login') }}>
              Sign out
            </MenuItem>
          </>
        )}
      </Menu>
      <ChangePasswordDialog open={changing} onClose={() => setChanging(false)} />
    </>
  )
}
