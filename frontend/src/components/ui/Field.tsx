import clsx from 'clsx'
import { forwardRef, useId, type InputHTMLAttributes, type ReactNode } from 'react'

export const inputClass = clsx(
  'h-10 w-full rounded-lg border border-border bg-surface px-3 text-sm text-fg placeholder:text-fg-subtle',
  'transition-[border-color,box-shadow] duration-200 ease-out-soft',
  'hover:border-border-strong focus:border-fg focus:outline-none focus:ring-4 focus:ring-fg/5',
  'disabled:opacity-60 aria-[invalid=true]:border-danger',
)

interface FieldProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string
  hint?: ReactNode
  error?: string | null
  trailing?: ReactNode
}

/** Label + input + hint/error, wired for screen readers. */
export const Field = forwardRef<HTMLInputElement, FieldProps>(function Field(
  { label, hint, error, trailing, className, id, ...rest }, ref,
) {
  const auto = useId()
  const inputId = id ?? auto
  const describedBy = error ? `${inputId}-err` : hint ? `${inputId}-hint` : undefined
  return (
    <div className={clsx('space-y-1.5', className)}>
      <label htmlFor={inputId} className="block text-[13px] font-medium text-fg">{label}</label>
      <div className="relative">
        <input ref={ref} id={inputId} aria-invalid={!!error} aria-describedby={describedBy}
               className={clsx(inputClass, trailing && 'pr-10')} {...rest} />
        {trailing && <div className="absolute inset-y-0 right-1 flex items-center">{trailing}</div>}
      </div>
      {error ? <p id={`${inputId}-err`} className="text-xs text-danger">{error}</p>
        : hint ? <p id={`${inputId}-hint`} className="text-xs text-fg-muted">{hint}</p> : null}
    </div>
  )
})
