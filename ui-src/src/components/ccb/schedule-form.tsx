import { Plus, X } from "lucide-react";
import { useState } from "react";
import type { FetchItem, RunbookItem, ScheduleSpec } from "@/lib/api";
import { cn } from "@/lib/utils";

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";
const field =
  "w-full rounded-md border border-black/10 bg-transparent px-2 py-1 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30";

/** Mon..Sun as shown; values are JavaScript/.NET day numbers (0 = Sunday). */
const DAYS: { label: string; value: number }[] = [
  { label: "Mo", value: 1 },
  { label: "Tu", value: 2 },
  { label: "We", value: 3 },
  { label: "Th", value: 4 },
  { label: "Fr", value: 5 },
  { label: "Sa", value: 6 },
  { label: "Su", value: 0 },
];
const WEEKDAYS = [1, 2, 3, 4, 5];

/** What a schedule starts: a message, a saved fetch prompt or a runbook (runbooks/*.runbook.md). */
export interface ScheduleTarget {
  kind: "chat" | "fetch" | "runbook";
  text?: string;
  name?: string;
}

function pad(n: number) {
  return String(n).padStart(2, "0");
}

/** Local 'yyyy-MM-ddTHH:mm' for the next full hour. */
function nextHour(): string {
  const d = new Date(Date.now() + 3600_000);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:00`;
}

/** The repeat rule for a set of days: every day, weekdays, or weekly on those days. */
export function repeatFor(days: number[]): "daily" | "weekdays" | "weekly" {
  const set = new Set(days);
  if (set.size === 7) return "daily";
  if (set.size === 5 && WEEKDAYS.every((d) => set.has(d))) return "weekdays";
  return "weekly";
}

/** Schedule a message, fetch or runbook: once at a date and time, or on chosen days at one or more times. */
export function ScheduleForm({
  initial,
  fetchItems,
  runbooks,
  onSave,
  onCancel,
}: {
  initial: ScheduleTarget;
  fetchItems: FetchItem[];
  runbooks: RunbookItem[];
  onSave: (spec: ScheduleSpec) => Promise<void>;
  onCancel: () => void;
}) {
  const [target, setTarget] = useState(initial.kind === "chat" ? "chat" : `${initial.kind}:${initial.name ?? ""}`);
  const [text, setText] = useState(initial.text ?? "");
  const [mode, setMode] = useState<"once" | "repeat">("repeat");
  const [at, setAt] = useState(nextHour());
  const [days, setDays] = useState<number[]>(WEEKDAYS);
  const [times, setTimes] = useState<string[]>(["08:00"]);
  const [newTime, setNewTime] = useState("");
  const [title, setTitle] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  const toggleDay = (d: number) => setDays((cur) => (cur.includes(d) ? cur.filter((x) => x !== d) : [...cur, d]));
  const addTime = () => {
    if (/^([01]\d|2[0-3]):[0-5]\d$/.test(newTime) && !times.includes(newTime)) setTimes([...times, newTime].sort());
    setNewTime("");
  };

  const save = async () => {
    setSaving(true);
    setError("");
    const [kind, ...rest] = target.split(":");
    const spec: ScheduleSpec = {
      kind: kind as ScheduleSpec["kind"],
      text: kind === "chat" ? text : undefined,
      name: kind === "chat" ? undefined : rest.join(":"),
      title: title.trim() || undefined,
      ...(mode === "once" ? { repeat: "once", at } : { repeat: repeatFor(days), days, times }),
    };
    try {
      await onSave(spec);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };

  const valid =
    (target === "chat" ? text.trim().length > 0 : target.split(":")[1]?.length > 0) &&
    (mode === "once" ? Boolean(at) : days.length > 0 && times.length > 0);

  return (
    <div className="space-y-2 rounded-lg border border-black/10 p-2 dark:border-white/10">
      <div className="font-medium text-sm">Schedule</div>
      <label className="block space-y-1">
        <span className="text-muted-foreground text-xs">What runs</span>
        <select className={field} onChange={(e) => setTarget(e.target.value)} value={target}>
          <option value="chat">A message to Copilot</option>
          {runbooks.length > 0 && (
            <optgroup label="Runbooks (runbooks/*.runbook.md)">
              {runbooks.map((r) => (
                <option key={r.name} value={`runbook:${r.name}`}>
                  {r.title}
                </option>
              ))}
            </optgroup>
          )}
          {fetchItems.length > 0 && (
            <optgroup label="Fetch prompts">
              {fetchItems.map((f) => (
                <option key={f.name} value={`fetch:${f.name}`}>
                  {f.name}
                </option>
              ))}
            </optgroup>
          )}
        </select>
      </label>
      {target === "chat" && (
        <textarea className={cn(field, "min-h-16 resize-y")} onChange={(e) => setText(e.target.value)} placeholder="The message to send, e.g. Update the weekly report" value={text} />
      )}

      <div className="flex gap-1">
        {(["repeat", "once"] as const).map((m) => (
          <button className={cn(flatButton, mode === m && "bg-black/10 dark:bg-white/15")} key={m} onClick={() => setMode(m)} type="button">
            {m === "repeat" ? "Repeat" : "Once"}
          </button>
        ))}
      </div>

      {mode === "once" ? (
        <input className={field} onChange={(e) => setAt(e.target.value)} type="datetime-local" value={at} />
      ) : (
        <div className="space-y-2">
          <div className="flex flex-wrap items-center gap-1">
            {DAYS.map((d) => (
              <button
                className={cn(
                  "h-7 w-8 rounded-md border text-xs",
                  days.includes(d.value) ? "border-black/30 bg-black/10 dark:border-white/30 dark:bg-white/15" : "border-black/10 text-muted-foreground dark:border-white/10"
                )}
                key={d.value}
                onClick={() => toggleDay(d.value)}
                type="button"
              >
                {d.label}
              </button>
            ))}
            <button className={flatButton} onClick={() => setDays(WEEKDAYS)} type="button">
              Weekdays
            </button>
            <button className={flatButton} onClick={() => setDays([0, 1, 2, 3, 4, 5, 6])} type="button">
              Every day
            </button>
          </div>
          <div className="flex flex-wrap items-center gap-1">
            {times.map((t) => (
              <span className="inline-flex items-center gap-1 rounded-md border border-black/10 px-1.5 py-0.5 font-mono text-xs dark:border-white/10" key={t}>
                {t}
                <button aria-label={`Remove ${t}`} className="text-muted-foreground hover:text-foreground" onClick={() => setTimes(times.filter((x) => x !== t))} type="button">
                  <X className="h-3 w-3" />
                </button>
              </span>
            ))}
            <input
              className="rounded-md border border-black/10 bg-transparent px-1.5 py-0.5 text-xs outline-none dark:border-white/10"
              onChange={(e) => setNewTime(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && addTime()}
              type="time"
              value={newTime}
            />
            <button className={flatButton} disabled={!newTime} onClick={addTime} title="Add this time" type="button">
              <Plus className="h-3 w-3" /> Time
            </button>
          </div>
        </div>
      )}

      <input className={field} onChange={(e) => setTitle(e.target.value)} placeholder="Name (optional)" value={title} />
      <p className="text-muted-foreground text-xs">Runs in this project while StreamHub is open; a run missed while it was closed runs once at the next start.</p>
      {error && <p className="text-rose-600 text-xs dark:text-rose-400">{error}</p>}
      <div className="flex justify-end gap-1">
        <button className={flatButton} onClick={onCancel} type="button">
          Cancel
        </button>
        <button className={cn(flatButton, "bg-black/5 dark:bg-white/10")} disabled={saving || !valid} onClick={save} type="button">
          {saving ? "Saving..." : "Schedule"}
        </button>
      </div>
    </div>
  );
}
