import { Moon, Sun } from 'lucide-react'
import { AnimatePresence, motion } from 'motion/react'
import { useTheme } from '../../lib/theme'

/** One-click light/dark switch; the icon rotates and fades into the other one. */
export function ThemeToggle() {
  const { dark, toggle } = useTheme()
  const Icon = dark ? Sun : Moon
  return (
    <button onClick={toggle} aria-label={dark ? 'Switch to light theme' : 'Switch to dark theme'}
            title={dark ? 'Light theme' : 'Dark theme'}
            className="relative flex size-9 items-center justify-center rounded-lg text-fg-muted transition-colors hover:bg-muted hover:text-fg">
      <AnimatePresence mode="wait" initial={false}>
        <motion.span key={dark ? 'sun' : 'moon'} initial={{ opacity: 0, rotate: -60, scale: 0.7 }}
                     animate={{ opacity: 1, rotate: 0, scale: 1 }} exit={{ opacity: 0, rotate: 60, scale: 0.7 }}
                     transition={{ duration: 0.18 }} className="flex">
          <Icon className="size-[18px]" strokeWidth={1.75} />
        </motion.span>
      </AnimatePresence>
    </button>
  )
}
