import { AtSign, FileText, Plus, X } from "lucide-react";
import { useMemo, useState } from "react";
import type { ChainItem, FetchItem, FileInfo, RunbookItem, ScheduleItem, ScheduleSpec } from "@/lib/api";
import {
  addTime,
  buildScheduleSpec,
  DAYS,
  EVERY_DAY,
  initialDays,
  initialTitle,
  isRunbookFile,
  missingParts,
  nextHour,
  pickableFiles,
  pickFile,
  WEEKDAYS,
  withPendingTime,
} from "@/lib/schedule-form";
import { cn } from "@/lib/utils";
import { KeepOpenNote, SCHEDULE_NOTE } from "./keep-open-note";

export { repeatFor } from "@/lib/schedule-form";

const flatButton =
  "kit-btn kit-btn--ghost kit-btn--sm";
const field =
  "kit-input h-8 min-h-8 w-full";

/** What a schedule starts: a message, a runbook (text answer: kind fetch; checked JSON: kind runbook) or a chain. */
export interface ScheduleTarget {
  kind: "chat" | "fetch" | "runbook" | "chain" | "script";
  text?: string;
  name?: string;
}

/** The list of what can run: a message, runbooks, chains, scripts and text-answer runbooks. */
function TargetSelect({
  target,
  setTarget,
  fetchItems,
  runbooks,
  chains,
  scripts,
}: {
  target: string;
  setTarget: (t: string) => void;
  fetchItems: FetchItem[];
  runbooks: RunbookItem[];
  chains: ChainItem[];
  scripts: string[];
}) {
  return (
    <select aria-label="What runs" className={field} onChange={(e) => setTarget(e.target.value)} value={target}>
      <option value="chat">A message to Copilot</option>
      {/* A runbook picked with @ that the list does not have (yet) still shows. */}
      {target.startsWith("runbook:") && !runbooks.some((r) => `runbook:${r.name}` === target) && (
        <option value={target}>Runbook: {target.slice(8)}</option>
      )}
      {runbooks.length > 0 && (
        <optgroup label="Runbooks with checked JSON">
          {runbooks.map((r) => (
            <option key={r.name} value={`runbook:${r.name}`}>
              {r.title}
            </option>
          ))}
        </optgroup>
      )}
      {chains.length > 0 && (
        <optgroup label="Chains (Runbooks/*.chain.md)">
          {chains.map((c) => (
            <option key={c.name} value={`chain:${c.name}`}>
              {c.title}
            </option>
          ))}
        </optgroup>
      )}
      {scripts.length > 0 && (
        <optgroup label="Scripts (Scripts/)">
          {scripts.map((p) => (
            <option key={p} value={`script:${p}`}>
              {p.replace(/^Scripts\//i, "")}
            </option>
          ))}
        </optgroup>
      )}
      {fetchItems.length > 0 && (
        <optgroup label="Runbooks with a text answer">
          {fetchItems.map((f) => (
            <option key={f.name} value={`fetch:${f.name}`}>
              {f.name}
            </option>
          ))}
        </optgroup>
      )}
    </select>
  );
}

/** The @ picker: a filter field and the matching project files. */
function FilePicker({
  files,
  filter,
  setFilter,
  onPick,
  onClose,
}: {
  files: FileInfo[];
  filter: string;
  setFilter: (f: string) => void;
  onPick: (path: string) => void;
  onClose: () => void;
}) {
  const pickable = useMemo(() => pickableFiles(files, filter), [files, filter]);
  return (
    <div className="kit-panel rounded-(--kit-radius) p-0">
      <input aria-label="Find a project file"
        autoFocus
        className="kit-input h-8 min-h-8 w-full"
        onChange={(e) => setFilter(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && pickable[0]) onPick(pickable[0].path);
          if (e.key === "Escape") {
            e.preventDefault();
            onClose();
          }
        }}
        placeholder="Type to filter, e.g. runbook or .md"
        value={filter}
      />
      <div className="max-h-48 overflow-y-auto py-1">
        {pickable.map((f) => (
          <button
            className="flex w-full items-center gap-1.5 px-2 py-0.5 text-left font-mono text-xs hover:bg-(--kit-surface-2)"
            key={f.path}
            onClick={() => onPick(f.path)}
            type="button"
          >
            <FileText className="h-3 w-3 shrink-0 text-muted-foreground" />
            <span className="truncate">{f.path}</span>
            {isRunbookFile(f.path) && <span className="ml-auto shrink-0 font-sans text-muted-foreground">runbook</span>}
          </button>
        ))}
        {!pickable.length && <p className="px-2 py-1 text-muted-foreground text-xs">No matching files.</p>}
      </div>
    </div>
  );
}

/** The day buttons, with Weekdays and Every day. */
function DayPicker({ days, setDays }: { days: number[]; setDays: (update: (cur: number[]) => number[]) => void }) {
  const toggleDay = (d: number) => setDays((cur) => (cur.includes(d) ? cur.filter((x) => x !== d) : [...cur, d]));
  return (
    <div className="flex flex-wrap items-center gap-1">
      {DAYS.map((d) => (
        <button
          className={cn(
            "h-7 w-8 rounded-md border text-xs",
            days.includes(d.value) ? "border-(--kit-border-strong) bg-(--kit-surface-2)" : "border-(--kit-border) text-muted-foreground"
          )}
          key={d.value}
          onClick={() => toggleDay(d.value)}
          type="button"
        >
          {d.label}
        </button>
      ))}
      <button className={flatButton} onClick={() => setDays(() => WEEKDAYS)} type="button">
        Weekdays
      </button>
      <button className={flatButton} onClick={() => setDays(() => EVERY_DAY)} type="button">
        Every day
      </button>
    </div>
  );
}

/** The chosen times, each removable, and a field to add one. */
function TimeList({
  times,
  setTimes,
  newTime,
  setNewTime,
}: {
  times: string[];
  setTimes: (t: string[]) => void;
  newTime: string;
  setNewTime: (t: string) => void;
}) {
  const add = () => {
    setTimes(addTime(times, newTime));
    setNewTime("");
  };
  return (
    <div className="flex flex-wrap items-center gap-1">
      {times.map((t) => (
        <span className="kit-badge rounded-(--kit-radius-sm) gap-1 font-mono font-normal text-foreground" key={t}>
          {t}
          <button aria-label={`Remove ${t}`} className="text-muted-foreground hover:text-foreground" onClick={() => setTimes(times.filter((x) => x !== t))} type="button">
            <X className="h-3 w-3" />
          </button>
        </span>
      ))}
      <input aria-label="Time to add"
        className="kit-input h-7 min-h-0 px-1.5 text-xs"
        onChange={(e) => setNewTime(e.target.value)}
        onKeyDown={(e) => e.key === "Enter" && add()}
        type="time"
        value={newTime}
      />
      <button className={flatButton} disabled={!newTime} onClick={add} title="Add this time" type="button">
        <Plus className="h-3 w-3" /> Time
      </button>
    </div>
  );
}

/** Schedule a message, fetch or runbook: once at a date and time, or on chosen days at one or more times. */
export function ScheduleForm({
  initial,
  existing,
  fetchItems,
  runbooks,
  chains = [],
  scripts = [],
  files = [],
  onSave,
  onCancel,
}: {
  initial: ScheduleTarget;
  /** Editing this schedule: the form opens with its settings. */
  existing?: ScheduleItem;
  fetchItems: FetchItem[];
  runbooks: RunbookItem[];
  chains?: ChainItem[];
  /** Scripts in Scripts/ that can run on a schedule. */
  scripts?: string[];
  /** Project files for the @ picker: a runbook from Runbooks/ runs as a runbook, any other file is attached to the message. */
  files?: FileInfo[];
  onSave: (spec: ScheduleSpec) => Promise<void>;
  onCancel: () => void;
}) {
  const [target, setTarget] = useState(initial.kind === "chat" ? "chat" : `${initial.kind}:${initial.name ?? ""}`);
  const [text, setText] = useState(initial.text ?? "");
  const [mode, setMode] = useState<"once" | "repeat">(existing?.repeat === "once" ? "once" : "repeat");
  const [at, setAt] = useState(existing?.repeat === "once" && existing.at ? existing.at.slice(0, 16) : nextHour());
  const [days, setDays] = useState<number[]>(() => initialDays(existing));
  const [times, setTimes] = useState<string[]>(existing?.times?.length ? existing.times : ["08:00"]);
  const [newTime, setNewTime] = useState("");
  const [title, setTitle] = useState(() => initialTitle(existing));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [picking, setPicking] = useState(false);
  const [filter, setFilter] = useState("");

  const pick = (path: string) => {
    const picked = pickFile(path, text);
    if ("error" in picked) {
      setError(picked.error);
      return;
    }
    setTarget(picked.target);
    if (picked.text !== undefined) setText(picked.text);
    setPicking(false);
    setFilter("");
  };

  const allTimes = withPendingTime(times, newTime);
  const form = { target, text, title, mode, at, days, times: allTimes };

  const save = async () => {
    setSaving(true);
    setError("");
    try {
      await onSave(buildScheduleSpec(form));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };

  const missing = missingParts(form);
  const valid = missing.length === 0;

  return (
    <div className="kit-panel space-y-2 p-2">
      <div className="font-medium text-sm">{existing ? "Edit schedule" : "Schedule"}</div>
      <div className="space-y-1">
        <span className="text-muted-foreground text-xs">What runs</span>
        <div className="flex gap-1">
          <TargetSelect chains={chains} fetchItems={fetchItems} runbooks={runbooks} scripts={scripts} setTarget={setTarget} target={target} />
          <button
            aria-label="Pick a project file"
            className={cn("shrink-0 rounded-md border border-(--kit-border) px-2 hover:bg-(--kit-surface-2)", picking && "bg-(--kit-surface-2)")}
            onClick={() => setPicking(!picking)}
            title="Pick a project file: a runbook (Runbooks/*.runbook.md) runs as a runbook; any other file, such as a Markdown file with instructions, is attached to the message"
            type="button"
          >
            <AtSign className="h-4 w-4" />
          </button>
        </div>
        {picking && <FilePicker files={files} filter={filter} setFilter={setFilter} onClose={() => setPicking(false)} onPick={pick} />}
      </div>
      {target === "chat" && (
        <textarea aria-label="Message to send" className={cn(field, "min-h-16 resize-y")} onChange={(e) => setText(e.target.value)} placeholder="The message to send, e.g. Update the weekly report" value={text} />
      )}

      <div className="flex gap-1">
        {(["repeat", "once"] as const).map((m) => (
          <button className={cn(flatButton, mode === m && "bg-(--kit-surface-2)")} key={m} onClick={() => setMode(m)} type="button">
            {m === "repeat" ? "Repeat" : "Once"}
          </button>
        ))}
      </div>

      {mode === "once" ? (
        <input aria-label="Date and time" className={field} onChange={(e) => setAt(e.target.value)} type="datetime-local" value={at} />
      ) : (
        <div className="space-y-2">
          <DayPicker days={days} setDays={setDays} />
          <TimeList newTime={newTime} setNewTime={setNewTime} setTimes={setTimes} times={times} />
        </div>
      )}

      <input aria-label="Schedule name" className={field} onChange={(e) => setTitle(e.target.value)} placeholder="Name (optional)" value={title} />
      <KeepOpenNote>{SCHEDULE_NOTE}</KeepOpenNote>
      {error && <p className="kit-error-text">{error}</p>}
      <div className="flex items-center justify-end gap-1">
        {!valid && <span className="mr-auto text-muted-foreground text-xs">To schedule it: {missing.join(", ")}.</span>}
        <button className={flatButton} onClick={onCancel} type="button">
          Cancel
        </button>
        <button className={cn(flatButton, "bg-(--kit-surface-2)")} disabled={saving || !valid} onClick={save} title={valid ? undefined : `Still needed: ${missing.join(", ")}`} type="button">
          {saving ? "Saving..." : existing ? "Save changes" : "Schedule"}
        </button>
      </div>
    </div>
  );
}
