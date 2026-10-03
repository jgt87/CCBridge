import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/markdown.css'
import App from './App.tsx'
import { ErrorBoundary } from './components/ccb/error-boundary.tsx'
import { reportClientError } from './lib/api.ts'

// Dark by default; follows the system when it prefers light.
if (!window.matchMedia('(prefers-color-scheme: light)').matches) document.documentElement.classList.add('dark')

window.addEventListener('error', (e) => reportClientError(`Page error: ${e.message}`, { stack: (e.error?.stack ?? '').split('\n').slice(0, 6).join(' | ') }))
window.addEventListener('unhandledrejection', (e) => reportClientError(`Unhandled promise rejection: ${String(e.reason?.message ?? e.reason)}`))

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ErrorBoundary area="app">
      <App />
    </ErrorBoundary>
  </StrictMode>,
)
