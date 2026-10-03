import { AtSign, FileText, Plus, X } from "lucide-react";
import { useMemo, useState } from "react";
import type { FetchItem, FileInfo, RunbookItem, ScheduleItem, ScheduleSpec } from "@/lib/api";
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
  existing,
  fetchItems,
  runbooks,
  files = [],
  onSave,
  onCancel,
}: {
  initial: ScheduleTarget;
  /** Editing this schedule: the form opens with its settings. */
  existing?: ScheduleItem;
  fetchItems: FetchItem[];
  runbooks: RunbookItem[];
  /** Project files for the @ picker: a runbook from runbooks/ runs as a runbook, any other file is attached to the message. */
  files?: FileInfo[];
  onSave: (spec: ScheduleSpec) => Promise<void>;
  onCancel: () => void;
}) {
  const [target, setTarget] = useState(initial.kind === "chat" ? "chat" : `${initial.kind}:${initial.name ?? ""}`);
  const [text, setText] = useState(initial.text ?? "");
  const [mode, setMode] = useState<"once" | "repeat">(existing?.repeat === "once" ? "once" : "repeat");
  const [at, setAt] = useState(existing?.repeat === "once" && existing.at ? existing.at.slice(0, 16) : nextHour());
  const [days, setDays] = useState<number[]>(() => {
    if (!existing || existing.repeat === "once") return WEEKDAYS;
    if (existing.repeat === "daily") return DAYS.map((d) => d.value);
    if (existing.repeat === "weekdays") return WEEKDAYS;
    return existing.days?.length ? existing.days : WEEKDAYS;
  });
  const [times, setTimes] = useState<string[]>(existing?.times?.length ? existing.times : ["08:00"]);
  const [newTime, setNewTime] = useState("");
  // A title the user typed; one made up from the message or name is not kept as a custom title.
  const [title, setTitle] = useState(() => {
    if (!existing) return "";
    const auto = existing.kind === "chat" ? (existing.text ?? "").replace(/\s+/g, " ").trim() : `${existing.kind}: ${existing.name}`;
    return existing.title === auto || existing.title === auto.slice(0, 117) + "..." ? "" : existing.title;
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [picking, setPicking] = useState(false);
  const [filter, setFilter] = useState("");

  // Markdown files (runbooks and instructions) first, then the rest; at most 50.
  const pickable = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return files
      .filter((f) => !q || f.path.toLowerCase().includes(q))
      .sort((a, b) => Number(!/\.md$/i.test(a.path)) - Number(!/\.md$/i.test(b.path)) || a.path.localeCompare(b.path))
      .slice(0, 50);
  }, [files, filter]);

  const pick = (path: string) => {
    const rb = path.match(/^runbooks\/([^/]+)\.runbook\.md$/i);
    if (rb) setTarget(`runbook:${rb[1]}`);
    else if (/\s/.test(path)) {
      setError(`${path} has a space in its path, so it cannot be attached with @. Rename it (for example with - instead of spaces) and pick it again.`);
      return;
    } else {
      setTarget("chat");
      setText((t) => (t.trim() ? `${t.trimEnd()} @${path}` : `Follow the instructions in @${path}`));
    }
    setPicking(false);
    setFilter("");
  };

  const toggleDay = (d: number) => setDays((cur) => (cur.includes(d) ? cur.filter((x) => x !== d) : [...cur, d]));
  const addTime = () => {
    if (/^([01]\d|2[0-3]):[0-5]\d$/.test(newTime) && !times.includes(newTime)) setTimes([...times, newTime].sort());
    setNewTime("");
  };

  // A time typed in the field counts too, also without pressing "+ Time".
  const pendingTime = /^([01]\d|2[0-3]):[0-5]\d$/.test(newTime) ? newTime : "";
  const allTimes = pendingTime && !times.includes(pendingTime) ? [...times, pendingTime].sort() : times;

  const save = async () => {
    setSaving(true);
    setError("");
    const [kind, ...rest] = target.split(":");
    const spec: ScheduleSpec = {
      kind: kind as ScheduleSpec["kind"],
      text: kind === "chat" ? text : undefined,
      name: kind === "chat" ? undefined : rest.join(":"),
      title: title.trim() || undefined,
      ...(mode === "once" ? { repeat: "once", at } : { repeat: repeatFor(days), days, times: allTimes }),
    };
    try {
      await onSave(spec);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };

  // What is still missing; shown next to the button instead of only greying it out.
  const missing: string[] = [];
  if (target === "chat" ? !text.trim() : !target.split(":")[1]) missing.push(target === "chat" ? "write the message" : "pick what runs");
  if (mode === "once") {
    if (!at) missing.push("pick the date and time");
  } else {
    if (!days.length) missing.push("pick at least one day");
    if (!allTimes.length) missing.push("add a time");
  }
  const valid = missing.length === 0;

  return (
    <div className="space-y-2 rounded-lg border border-black/10 p-2 dark:border-white/10">
      <div className="font-medium text-sm">{existing ? "Edit schedule" : "Schedule"}</div>
      <div className="space-y-1">
        <span className="text-muted-foreground text-xs">What runs</span>
        <div className="flex gap-1">
        <select className={field} onChange={(e) => setTarget(e.target.value)} value={target}>
          <option value="chat">A message to Copilot</option>
          {/* A runbook picked with @ that the list does not have (yet) still shows. */}
          {target.startsWith("runbook:") && !runbooks.some((r) => `runbook:${r.name}` === target) && (
            <option value={target}>Runbook: {target.slice(8)}</option>
          )}
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
          <button
            aria-label="Pick a project file"
            className={cn("shrink-0 rounded-md border border-black/10 px-2 hover:bg-black/5 dark:border-white/10 dark:hover:bg-white/5", picking && "bg-black/10 dark:bg-white/15")}
            onClick={() => setPicking(!picking)}
            title="Pick a project file: a runbook (runbooks/*.runbook.md) runs as a runbook; any other file, such as a Markdown file with instructions, is attached to the message"
            type="button"
          >
            <AtSign className="h-4 w-4" />
          </button>
        </div>
        {picking && (
          <div className="rounded-md border border-black/10 dark:border-white/10">
            <input
              autoFocus
              className="w-full border-black/10 border-b bg-transparent px-2 py-1 text-sm outline-none dark:border-white/10"
              onChange={(e) => setFilter(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && pickable[0]) pick(pickable[0].path);
                if (e.key === "Escape") {
                  e.preventDefault();
                  setPicking(false);
                }
              }}
              placeholder="Type to filter, e.g. runbook or .md"
              value={filter}
            />
            <div className="max-h-48 overflow-y-auto py-1">
              {pickable.map((f) => (
                <button
                  className="flex w-full items-center gap-1.5 px-2 py-0.5 text-left font-mono text-xs hover:bg-black/5 dark:hover:bg-white/5"
                  key={f.path}
                  onClick={() => pick(f.path)}
                  type="button"
                >
                  <FileText className="h-3 w-3 shrink-0 text-muted-foreground" />
                  <span className="truncate">{f.path}</span>
                  {/^runbooks\/[^/]+\.runbook\.md$/i.test(f.path) && <span className="ml-auto shrink-0 font-sans text-muted-foreground">runbook</span>}
                </button>
              ))}
              {!pickable.length && <p className="px-2 py-1 text-muted-foreground text-xs">No matching files.</p>}
            </div>
          </div>
        )}
      </div>
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
      <div className="flex items-center justify-end gap-1">
        {!valid && <span className="mr-auto text-muted-foreground text-xs">To schedule it: {missing.join(", ")}.</span>}
        <button className={flatButton} onClick={onCancel} type="button">
          Cancel
        </button>
        <button className={cn(flatButton, "bg-black/5 dark:bg-white/10")} disabled={saving || !valid} onClick={save} title={valid ? undefined : `Still needed: ${missing.join(", ")}`} type="button">
          {saving ? "Saving..." : existing ? "Save changes" : "Schedule"}
        </button>
      </div>
    </div>
  );
}
