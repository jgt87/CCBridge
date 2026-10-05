// The page a project's app starts from, for "Open app" in the Files section: a build's output
// (dist/, build/ or out/index.html: Vite, Create React App, Next export) before a plain index.html
// at the project root. Opened on the read-only preview address, where module scripts work (they
// do not from a file opened from disk).

const ENTRY_PAGES = ["dist/index.html", "build/index.html", "out/index.html", "index.html"];

export function findAppEntry(paths: string[]): string | null {
  const have = new Set(paths.map((p) => p.split("\\").join("/").toLowerCase()));
  return ENTRY_PAGES.find((p) => have.has(p)) ?? null;
}

/** The entry page's address on the preview (previewBase is /preview/TOKEN/). */
export function appEntryUrl(previewBase: string, entry: string): string {
  return `${window.location.origin}${previewBase}${entry.split("/").map(encodeURIComponent).join("/")}`;
}
