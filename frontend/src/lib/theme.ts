import { useEffect, useState } from 'react'

export type Theme = 'light' | 'dark' | 'system'

function apply(theme: Theme) {
  const dark = theme === 'dark' || (theme === 'system' && matchMedia('(prefers-color-scheme: dark)').matches)
  document.documentElement.classList.toggle('dark', dark)
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', dark ? '#09090b' : '#ffffff')
}

function saved(): Theme {
  try { return (localStorage.getItem('theme') as Theme) || 'system' } catch { return 'system' }
}

export function useTheme() {
  const [theme, setTheme] = useState<Theme>(saved)

  useEffect(() => {
    apply(theme)
    try { localStorage.setItem('theme', theme) } catch { /* private mode */ }
    if (theme !== 'system') return
    const mq = matchMedia('(prefers-color-scheme: dark)')
    const follow = () => apply('system')
    mq.addEventListener('change', follow)
    return () => mq.removeEventListener('change', follow)
  }, [theme])

  return { theme, setTheme }
}
