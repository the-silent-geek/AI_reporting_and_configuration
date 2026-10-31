import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig, loadEnv } from 'vite'

// The API runs on :8000 (override with VITE_API_TARGET in .env.local). Proxying /api
// keeps the UI and API on one origin, so the httpOnly refresh cookie
// (SameSite=Strict, Path=/api/auth) just works.
export default defineConfig(({ mode }) => ({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: { '/api': { target: loadEnv(mode, process.cwd(), '').VITE_API_TARGET || 'http://127.0.0.1:8000' } },
  },
}))
