import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig, loadEnv } from 'vite'

// The API runs on :8000. Proxying /api keeps the UI and API on one origin, so the
// httpOnly refresh cookie (SameSite=Strict, Path=/api/auth) just works.
// Default: API on this same machine. To use the API running on the host PC instead,
// set VITE_API_TARGET in frontend/.env.local (see docs/TEAM_SETUP.md).
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  return {
    plugins: [react(), tailwindcss()],
    server: {
      port: 5173,
      proxy: { '/api': { target: env.VITE_API_TARGET || 'http://127.0.0.1:8000' } },
    },
  }
})
