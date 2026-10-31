/* API client.

   Access token: memory only (never localStorage), attached as Bearer.
   Refresh token: httpOnly cookie the browser sends to /api/auth/refresh.
   On 401 we refresh ONCE and retry. Refresh is single-flight: the server rotates
   the token on every refresh and treats a replayed old token as theft (logs the
   user out everywhere), so two parallel refreshes must never happen. */
import { fetchEventSource } from '@microsoft/fetch-event-source'
import type { User } from './types'

let accessToken: string | null = null
let onSessionLost: () => void = () => {}

export function setAccessToken(token: string | null) { accessToken = token }
export function onSessionEnded(fn: () => void) { onSessionLost = fn }

export class ApiError extends Error {
  status: number
  detail: unknown
  constructor(status: number, detail: unknown) {
    super(typeof detail === 'string' ? detail : (detail as { status?: string })?.status ?? `HTTP ${status}`)
    this.status = status
    this.detail = detail
  }
}

export interface RefreshResult { access_token: string; user: User; app_code: string | null }

let refreshing: Promise<RefreshResult | null> | null = null

/** Single-flight refresh. Resolves null when there is no valid session. */
export function refreshSession(): Promise<RefreshResult | null> {
  refreshing ??= fetch('/api/auth/refresh', { method: 'POST', credentials: 'same-origin' })
    .then(async (r) => {
      if (!r.ok) return null
      const body = (await r.json()) as RefreshResult
      accessToken = body.access_token
      return body
    })
    .catch(() => null)
    .finally(() => { setTimeout(() => { refreshing = null }, 0) })
  return refreshing
}

async function parse(r: Response) {
  if (r.status === 204) return null
  const text = await r.text()
  try { return text ? JSON.parse(text) : null } catch { return text }
}

export async function api<T = unknown>(path: string, init: RequestInit = {}, retry = true): Promise<T> {
  const headers = new Headers(init.headers)
  if (accessToken) headers.set('Authorization', `Bearer ${accessToken}`)
  if (init.body && !(init.body instanceof FormData) && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json')
  }
  const r = await fetch(path, { ...init, headers, credentials: 'same-origin' })

  if (r.status === 401 && retry && !path.startsWith('/api/auth/')) {
    if (await refreshSession()) return api<T>(path, init, false)
    onSessionLost()
  }
  const body = await parse(r)
  if (!r.ok) throw new ApiError(r.status, (body as { detail?: unknown })?.detail ?? body)
  return body as T
}

export const json = (data: unknown): RequestInit => ({ body: JSON.stringify(data) })

/** Upload with real progress (fetch can't report upload progress; XHR can). */
export function uploadFile(
  path: string, form: FormData, onProgress: (pct: number) => void, signal?: AbortSignal,
): Promise<{ status: number; body: any }> {
  const send = () => new Promise<{ status: number; body: any }>((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open('POST', path)
    if (accessToken) xhr.setRequestHeader('Authorization', `Bearer ${accessToken}`)
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(Math.round((e.loaded / e.total) * 100))
    xhr.onload = () => {
      let body: any = null
      try { body = JSON.parse(xhr.responseText) } catch { body = xhr.responseText }
      resolve({ status: xhr.status, body })
    }
    xhr.onerror = () => reject(new ApiError(0, 'Network error'))
    xhr.onabort = () => reject(new DOMException('Aborted', 'AbortError'))
    signal?.addEventListener('abort', () => xhr.abort())
    xhr.send(form)
  })
  return send().then(async (res) => {
    if (res.status === 401 && (await refreshSession())) return send()
    return res
  })
}

class TokenExpired extends Error {}

/** Server-Sent Events with the Authorization header (native EventSource can't send it).
    Network drops: retried every 2 s, resuming from the last event id.
    Expired token: refresh, then reconnect with the new token from the same event id.
    403/404: stop and reject. */
export async function streamEvents<T extends { event_id: number }>(
  path: string, onEvent: (data: T) => void, signal: AbortSignal,
) {
  let lastId = 0
  while (!signal.aborted) {
    try {
      await fetchEventSource(path, {
        signal,
        openWhenHidden: true,
        headers: {
          ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
          ...(lastId ? { 'Last-Event-ID': String(lastId) } : {}),
        },
        async onopen(r) {
          if (r.status === 401) throw new TokenExpired()
          if (!r.ok) throw new ApiError(r.status, 'stream failed')
        },
        onmessage(msg) {
          if (msg.event === 'session_ended') { onSessionLost(); return }
          if (msg.event !== 'progress' || !msg.data) return
          const data = JSON.parse(msg.data) as T
          lastId = Math.max(lastId, data.event_id)
          onEvent(data)
        },
        onerror(err) {
          if (err instanceof TokenExpired || err instanceof ApiError) throw err
          return 2000
        },
      })
      return
    } catch (err) {
      if (!(err instanceof TokenExpired)) throw err
      if (!(await refreshSession())) { onSessionLost(); return }
    }
  }
}
