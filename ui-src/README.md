# StreamHub web interface

The source of StreamHub's web app. It builds into `../ui`, which the app serves; target PCs never need Node.

```powershell
npm install        # once, on a development PC
npm run build      # writes ../ui (commit it)
npm test           # unit tests (Vitest)
npm run dev        # development server; /api goes to the running app on port 8765
```

- Stack: React, TypeScript, Vite, Tailwind CSS, Kokonut UI components (adapted in `src/components/kokonutui`).
- Layout: components in `src/components/ccb`, the API client in `src/lib/api.ts`, helpers in `src/lib`.
- Style: monochrome white and grey, flat buttons; one part per file.
- The build replaces links to other GitHub repositories in the bundled libraries' messages with plain words (`vite.config.ts`), so the app refers to no repository but its own.

See the main [README](../README.md) and [AGENTS.md](../AGENTS.md) for the whole app.
