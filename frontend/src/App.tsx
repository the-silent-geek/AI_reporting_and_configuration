import { Compass, Loader2 } from 'lucide-react'
import { MotionConfig } from 'motion/react'
import type { ReactNode } from 'react'
import { BrowserRouter, Link, Navigate, Route, Routes, useLocation } from 'react-router-dom'
import { AppShell } from './components/layout/AppShell'
import { Button } from './components/ui/Button'
import { Brand, EmptyState } from './components/ui/Misc'
import { ToastProvider } from './components/ui/Toast'
import { AuthProvider, useAuth } from './lib/auth'
import { Launcher } from './pages/Launcher'
import { Login } from './pages/Login'
import { AdminUsers } from './pages/app/AdminUsers'
import { Assistant } from './pages/app/Assistant'
import { BatchDetail } from './pages/app/BatchDetail'
import { Templates } from './pages/app/Templates'
import { Dashboard } from './pages/app/Dashboard'
import { QualityDetail, QualityQueue } from './pages/app/DataQuality'
import { Datasets } from './pages/app/Datasets'
import { MappingEditor, MappingQueue } from './pages/app/MappingReview'
import { Reports } from './pages/app/Reports'
import { RecordTemplate } from './pages/app/RecordTemplate'
import { Upload } from './pages/app/Upload'

function RequireAuth({ children }: { children: ReactNode }) {
  const { status } = useAuth()
  const { pathname } = useLocation()
  if (status === 'loading') {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-6">
        <Brand />
        <Loader2 className="size-4 animate-spin text-fg-muted" />
      </div>
    )
  }
  if (status === 'anonymous') return <Navigate to="/login" replace state={{ from: pathname }} />
  return <>{children}</>
}

function NotFound() {
  return (
    <div className="flex h-full items-center justify-center">
      <EmptyState icon={Compass} title="Page not found" action={<Link to="/"><Button>Home</Button></Link>}>
        The page you're looking for doesn't exist.
      </EmptyState>
    </div>
  )
}

export default function App() {
  return (
    // Respects the OS "reduce motion" setting for every animation.
    <MotionConfig reducedMotion="user">
      <ToastProvider>
        <AuthProvider>
          <BrowserRouter>
            <Routes>
              <Route path="/login" element={<Login />} />
              <Route path="/" element={<RequireAuth><Launcher /></RequireAuth>} />
              <Route path="/app/:appCode" element={<RequireAuth><AppShell /></RequireAuth>}>
                <Route path="dashboard" element={<Dashboard />} />
                <Route path="datasets" element={<Datasets />} />
                <Route path="datasets/upload" element={<Upload />} />
                <Route path="datasets/:batchId" element={<BatchDetail />} />
                <Route path="mapping" element={<MappingQueue />} />
                <Route path="mapping/:batchId" element={<MappingEditor />} />
                <Route path="data-quality" element={<QualityQueue />} />
                <Route path="data-quality/:batchId" element={<QualityDetail />} />
                <Route path="reports" element={<Reports />} />
                <Route path="templates" element={<Templates />} />
                <Route path="templates/record" element={<RecordTemplate />} />
                <Route path="assistant" element={<Assistant />} />
                <Route path="admin" element={<Navigate to="users" replace />} />
                <Route path="admin/users" element={<AdminUsers />} />
                <Route path="*" element={<NotFound />} />
              </Route>
              <Route path="*" element={<NotFound />} />
            </Routes>
          </BrowserRouter>
        </AuthProvider>
      </ToastProvider>
    </MotionConfig>
  )
}
