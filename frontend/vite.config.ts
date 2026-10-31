import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// The API runs on :8000. Proxying /api keeps the UI and API on one origin, so the
// httpOnly refresh cookie (SameSite=Strict, Path=/api/auth) just works.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: { '/api': { target: 'http://127.0.0.1:8000' } },
  },
})
