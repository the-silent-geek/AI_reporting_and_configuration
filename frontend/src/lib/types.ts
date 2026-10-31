// Shapes returned by the API (see docs/API_GUIDE.md).

export type AppCode = 'ERP' | 'AML' | 'LENDING'

export interface User {
  user_id: string
  email: string
  full_name: string
  is_super_admin: boolean
}

export interface AppCard {
  code: AppCode
  name: string
  description: string
  icon: string
  route: string
  roles: string[]
}

export interface MenuItem {
  code: string
  label: string
  route: string
  icon: string
  children?: MenuItem[]
}

export interface AppContext {
  app: { code: AppCode; name: string; route: string; icon: string }
  roles: string[]
  permissions: string[]
  sidebar: MenuItem[]
}

export type BatchStatus =
  | 'UPLOADED' | 'EXTRACTING' | 'MAPPING_REVIEW' | 'VALIDATING'
  | 'READY_TO_COMMIT' | 'COMMITTED' | 'NEEDS_REVIEW' | 'FAILED'

export interface BatchSummary {
  batch_id: string
  batch_code: string
  file_name: string
  file_type: 'CSV' | 'EXCEL' | 'JSON' | 'PDF'
  status: BatchStatus
  progress_pct: number
  uploaded_by: string
  uploaded_at: string
}

export interface Batch extends BatchSummary {
  batch_no: number
  progress_message: string | null
  mime_type: string | null
  file_size_bytes: number
  sha256: string
  source_system: string | null
  period_start: string | null
  period_end: string | null
  error_message: string | null
  committed_by: string | null
  committed_at: string | null
  counts: { received: number; accepted: number; rejected: number; needs_review: number; pending: number }
}

export interface BatchEvent {
  event_id: number
  batch_id: string
  status: BatchStatus
  progress_pct: number
  message: string | null
  created_at: string
}

export interface AdminUser {
  user_id: string
  email: string
  full_name: string
  is_active: boolean
  is_super_admin: boolean
  last_login_at: string | null
  locked: boolean
  roles: string[]
}
