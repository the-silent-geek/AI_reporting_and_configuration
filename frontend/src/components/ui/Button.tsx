import clsx from 'clsx'
import { Loader2, type LucideIcon } from 'lucide-react'
import { forwardRef, type ButtonHTMLAttributes } from 'react'

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger'
type Size = 'sm' | 'md' | 'icon'

const VARIANT: Record<Variant, string> = {
  // One solid button per view (black in light, white in dark). Everything else stays quiet.
  primary: 'bg-accent text-accent-fg hover:opacity-90 shadow-sm',
  secondary: 'bg-surface text-fg border border-border hover:bg-muted hover:border-border-strong',
  ghost: 'text-fg-muted hover:text-fg hover:bg-muted',
  danger: 'bg-surface text-danger border border-border hover:border-danger/40 hover:bg-danger/5',
}
const SIZE: Record<Size, string> = {
  sm: 'h-8 px-3 text-[13px] gap-1.5 rounded-md',
  md: 'h-9 px-4 text-sm gap-2 rounded-lg',
  icon: 'h-9 w-9 rounded-lg justify-center',
}

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant
  size?: Size
  loading?: boolean
  icon?: LucideIcon
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = 'secondary', size = 'md', loading, icon: Icon, className, children, disabled, ...rest }, ref,
) {
  return (
    <button
      ref={ref}
      disabled={disabled || loading}
      className={clsx(
        'inline-flex shrink-0 items-center font-medium whitespace-nowrap select-none',
        'transition-[background-color,border-color,color,opacity,transform] duration-200 ease-out-soft',
        'active:scale-[0.98] disabled:pointer-events-none disabled:opacity-50',
        VARIANT[variant], SIZE[size], className,
      )}
      {...rest}
    >
      {loading ? <Loader2 className="size-4 animate-spin" /> : Icon && <Icon className="size-4" strokeWidth={1.75} />}
      {children}
    </button>
  )
})
