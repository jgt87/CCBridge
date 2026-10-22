import type { FileInfo, ScheduleItem, ScheduleSpec } from "./api";

/** Mon..Sun as shown; values are JavaScript/.NET day numbers (0 = Sunday). */
export const DAYS: { label: string; value: number }[] = [
  { label: "Mo", value: 1 },
  { label: "Tu", value: 2 },
  { label: "We", value: 3 },
  { label: "Th", value: 4 },
  { label: "Fr", value: 5 },
  { label: "Sa", value: 6 },
  { label: "Su", value: 0 },
];
export const WEEKDAYS = [1, 2, 3, 4, 5];
export const EVERY_DAY = [0, 1, 2, 3, 4, 5, 6];

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;
const RUNBOOK_FILE = /^runbooks\/([^/]+)\.runbook\.md$/i;

function pad(n: number) {
  return String(n).padStart(2, "0");
}

/** Local 'yyyy-MM-ddTHH:mm' for the next full hour. */
export function nextHour(now = Date.now()): string {
  const d = new Date(now + 3600_000);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:00`;
}

/** The repeat rule for a set of days: every day, weekdays, or weekly on those days. */
export function repeatFor(days: number[]): "daily" | "weekdays" | "weekly" {
  const set = new Set(days);
  if (set.size === 7) return "daily";
  if (set.size === 5 && WEEKDAYS.every((d) => set.has(d))) return "weekdays";
  return "weekly";
}

/** The days an existing schedule runs on; weekdays for a new or one-off schedule. */
export function initialDays(existing: ScheduleItem | undefined): number[] {
  if (!existing || existing.repeat === "once") return WEEKDAYS;
  if (existing.repeat === "daily") return DAYS.map((d) => d.value);
  if (existing.repeat === "weekdays") return WEEKDAYS;
  return existing.days?.length ? existing.days : WEEKDAYS;
}

/** A title the user typed; one made up from the message or name is not kept as a custom title. */
export function initialTitle(existing: ScheduleItem | undefined): string {
  if (!existing) return "";
  const auto = existing.kind === "chat" ? (existing.text ?? "").replace(/\s+/g, " ").trim() : `${existing.kind}: ${existing.name}`;
  return existing.title === auto || existing.title === auto.slice(0, 117) + "..." ? "" : existing.title;
}

export function isRunbookFile(path: string): boolean {
  return RUNBOOK_FILE.test(path);
}

/** Markdown files (runbooks and instructions) first, then the rest; at most 50. */
export function pickableFiles(files: FileInfo[], filter: string): FileInfo[] {
  const q = filter.trim().toLowerCase();
  return files
    .filter((f) => !q || f.path.toLowerCase().includes(q))
    .sort((a, b) => Number(!/\.md$/i.test(a.path)) - Number(!/\.md$/i.test(b.path)) || a.path.localeCompare(b.path))
    .slice(0, 50);
}

/** A file picked with @: a runbook runs as a runbook, any other file is attached to the message. */
export function pickFile(path: string, text: string): { target: string; text?: string } | { error: string } {
  const rb = path.match(RUNBOOK_FILE);
  if (rb) return { target: `runbook:${rb[1]}` };
  if (/\s/.test(path)) {
    return { error: `${path} has a space in its path, so it cannot be attached with @. Rename it (for example with - instead of spaces) and pick it again.` };
  }
  return { target: "chat", text: text.trim() ? `${text.trimEnd()} @${path}` : `Follow the instructions in @${path}` };
}

/** The times with a valid new one added, sorted. */
export function addTime(times: string[], time: string): string[] {
  return TIME.test(time) && !times.includes(time) ? [...times, time].sort() : times;
}

/** A time typed in the field counts too, also without pressing "+ Time". */
export function withPendingTime(times: string[], typed: string): string[] {
  return addTime(times, typed);
}

export interface ScheduleFormState {
  /** "chat" or "KIND:NAME". */
  target: string;
  text: string;
  title: string;
  mode: "once" | "repeat";
  at: string;
  days: number[];
  /** Every time, the typed one included. */
  times: string[];
}

export function buildScheduleSpec(s: ScheduleFormState): ScheduleSpec {
  const [kind, ...rest] = s.target.split(":");
  return {
    kind: kind as ScheduleSpec["kind"],
    text: kind === "chat" ? s.text : undefined,
    name: kind === "chat" ? undefined : rest.join(":"),
    title: s.title.trim() || undefined,
    ...(s.mode === "once" ? { repeat: "once", at: s.at } : { repeat: repeatFor(s.days), days: s.days, times: s.times }),
  };
}

/** What is still missing; shown next to the button instead of only greying it out. */
export function missingParts(s: Omit<ScheduleFormState, "title">): string[] {
  const missing: string[] = [];
  const chat = s.target === "chat";
  if (chat ? !s.text.trim() : !s.target.split(":")[1]) missing.push(chat ? "write the message" : "pick what runs");
  if (s.mode === "once") {
    if (!s.at) missing.push("pick the date and time");
    return missing;
  }
  if (!s.days.length) missing.push("pick at least one day");
  if (!s.times.length) missing.push("add a time");
  return missing;
}

/** The line under "Open schedules": how many are active, paused or done, and when the next one runs. */
export function schedulesSummaryText(schedules: ScheduleItem[], formatWhen: (iso: string | null) => string): string {
  if (schedules.length === 0) return "Run messages, runbooks and chains on set days and times";
  const active = schedules.filter((s) => s.enabled && s.nextRun);
  const next = [...active].sort((a, b) => String(a.nextRun).localeCompare(String(b.nextRun)))[0];
  const paused = schedules.length - active.length;
  return `${active.length} active${paused > 0 ? `, ${paused} paused or done` : ""}${next ? ` · next ${formatWhen(next.nextRun)}` : ""}`;
}
