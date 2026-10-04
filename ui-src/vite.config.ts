import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig, type Plugin } from 'vite'

/**
 * The bundled libraries mention their own GitHub pages in error and help messages. The shipped
 * app refers to no repository but its own, so those links become plain words in the build output.
 */
export function stripOtherRepoLinks(code: string): string {
  return code.replace(/https?:\/\/(?:www\.)?(?:github\.com|raw\.githubusercontent\.com)\/(?!jgt87\/CCBridge\b)[\w.\-/#?=&%~]*/g, 'the library documentation')
}

const noOtherRepoLinks: Plugin = {
  name: 'no-other-repo-links',
  apply: 'build',
  generateBundle(_options, bundle) {
    for (const file of Object.values(bundle)) {
      if (file.type === 'chunk') file.code = stripOtherRepoLinks(file.code)
      else if (typeof file.source === 'string') file.source = stripOtherRepoLinks(file.source)
    }
  },
}

// Built files go to ../ui, which ccbridge.ps1 serves; target machines never run Node.
export default defineConfig({
  plugins: [react(), tailwindcss(), noOtherRepoLinks],
  base: './',
  resolve: { alias: { '@': path.resolve(import.meta.dirname, './src') } },
  build: { outDir: '../ui', emptyOutDir: true, chunkSizeWarningLimit: 1500 },
  server: { proxy: { '/api': 'http://localhost:8765' } },
})
