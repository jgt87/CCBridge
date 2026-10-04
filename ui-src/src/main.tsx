import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './styles/markdown.css'
import App from './App.tsx'
import { ErrorBoundary } from './components/ccb/error-boundary.tsx'
import { reportClientError } from './lib/api.ts'
import { initTheme } from './lib/theme.ts'

// Theme from Settings (system / light / dark), before the first render so nothing flashes.
initTheme()

window.addEventListener('error', (e) => reportClientError(`Page error: ${e.message}`, { stack: (e.error?.stack ?? '').split('\n').slice(0, 6).join(' | ') }))
window.addEventListener('unhandledrejection', (e) => reportClientError(`Unhandled promise rejection: ${String(e.reason?.message ?? e.reason)}`))

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ErrorBoundary area="app">
      <App />
    </ErrorBoundary>
  </StrictMode>,
)

// Every web link in the app opens in a new tab (also links without target="_blank"), so the app
// itself never navigates away. Links within the page (#...) and file links handled by the app stay.
function openLinksInNewTab(e: MouseEvent) {
  if (e.defaultPrevented || e.button !== 0) return;
  const a = (e.target as Element | null)?.closest?.("a[href]") as HTMLAnchorElement | null;
  if (!a || !/^https?:/i.test(a.href) || a.origin === window.location.origin) return;
  e.preventDefault();
  window.open(a.href, "_blank", "noopener,noreferrer");
}
document.addEventListener("click", openLinksInNewTab);
