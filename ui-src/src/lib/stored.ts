// Per-browser choices kept in localStorage (open sections, the side panel's tab, closed folders).
// Storage can be blocked (a private window, a company policy): a read then gives the fallback and a
// write is skipped, so the page works the same, only without remembering the choice.

/** The stored text, or null when there is none or storage is blocked. */
export function readStored(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

/** Stores the text; when storage is blocked the choice lasts only until the page reloads. */
export function writeStored(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* storage blocked: nothing to remember it in */
  }
}

/** Stored JSON that passes `accept`, else the fallback (also for missing or damaged JSON). */
export function readStoredJson<T>(key: string, fallback: T, accept: (v: unknown) => v is T): T {
  const raw = readStored(key);
  if (raw === null) return fallback;
  try {
    const v: unknown = JSON.parse(raw);
    return accept(v) ? v : fallback;
  } catch {
    return fallback;
  }
}
