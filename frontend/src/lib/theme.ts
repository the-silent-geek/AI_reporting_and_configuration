import { useEffect, useState } from 'react'

export type Theme = 'light' | 'dark' | 'system'

const query = () => matchMedia('(prefers-color-scheme: dark)')

function apply(dark: boolean) {
  document.documentElement.classList.toggle('dark', dark)
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', dark ? '#09090b' : '#ffffff')
}

function saved(): Theme {
  try { return (localStorage.getItem('theme') as Theme) || 'system' } catch { return 'system' }
}

export function useTheme() {
  const [theme, setTheme] = useState<Theme>(saved)
  const [systemDark, setSystemDark] = useState(() => query().matches)
  const dark = theme === 'dark' || (theme === 'system' && systemDark)

  useEffect(() => {
    const mq = query()
    const follow = () => setSystemDark(mq.matches)
    mq.addEventListener('change', follow)
    return () => mq.removeEventListener('change', follow)
  }, [])

  useEffect(() => {
    apply(dark)
    try { localStorage.setItem('theme', theme) } catch { /* private mode */ }
  }, [theme, dark])

  return { theme, setTheme, dark, toggle: () => setTheme(dark ? 'light' : 'dark') }
}
