/**
 * The time shown next to each chat item: HH:mm for today, day and month before it for an earlier
 * day, the full date and time (with seconds) on hover, and for an action that finished how long it took.
 */

/** When an event happened: its ISO stamp (at), else its time text (HH:mm:ss today, or yyyy-MM-dd HH:mm). */
export function eventDate(time?: string, at?: string, now: Date = new Date()): Date | null {
  if (at) {
    const d = new Date(at);
    if (!Number.isNaN(d.getTime())) return d;
  }
  if (!time) return null;
  const full = time.match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/);
  if (full) return new Date(+full[1], +full[2] - 1, +full[3], +full[4], +full[5], +(full[6] ?? 0));
  const hms = time.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/);
  if (hms) return new Date(now.getFullYear(), now.getMonth(), now.getDate(), +hms[1], +hms[2], +(hms[3] ?? 0));
  return null;
}

const pad = (n: number) => String(n).padStart(2, "0");
const sameDay = (a: Date, b: Date) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();

/** How long something took, short: 8 s, 2 min 5 s, 1 h 4 min. */
export function formatDuration(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  if (m < 60) return s % 60 ? `${m} min ${s % 60} s` : `${m} min`;
  return `${Math.floor(m / 60)} h ${m % 60} min`;
}

export interface RowTime {
  /** What the column shows. */
  label: string;
  /** The full date and time, and the duration, for the tooltip. */
  title: string;
  /** How long an action took, when it finished. */
  took?: string;
}

/** The label and tooltip for an item that happened at (time, at), and for an action that ended at endAt. */
export function rowTime(time?: string, at?: string, endAt?: string, now: Date = new Date()): RowTime | null {
  const d = eventDate(time, at, now);
  if (!d) return time ? { label: time, title: time } : null;
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const day = sameDay(d, now) ? "" : d.toLocaleDateString(undefined, { day: "numeric", month: "short", ...(d.getFullYear() === now.getFullYear() ? {} : { year: "numeric" }) });
  const full = `${d.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "long", year: "numeric" })} ${hm}:${pad(d.getSeconds())}`;
  const end = endAt ? eventDate(undefined, endAt, now) : null;
  const took = end && end.getTime() >= d.getTime() ? formatDuration(end.getTime() - d.getTime()) : undefined;
  return { label: day ? `${day} ${hm}` : hm, title: took ? `${full} (took ${took})` : full, ...(took ? { took } : {}) };
}
