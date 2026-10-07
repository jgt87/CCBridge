import { AtSign, CalendarClock, FileCode2, FileText, Play, Plus } from "lucide-react";
import { InfoNote } from "./info-note";
import { useState } from "react";
import type { FetchItem, FetchWeb, RunbookItem, RunbookTemplate } from "@/lib/api";
import { cn } from "@/lib/utils";
import { fetchedAge, TextRunbookForm, webSummary } from "./fetch-panel";

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";
const field =
  "w-full rounded-md border border-black/10 bg-transparent px-2 py-1 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30";

/** Two kinds behind one list: a text answer (NAME.prompt.md, saved as Markdown) or checked JSON (NAME.runbook.md). */
export type RunbookKind = "text" | "json";

export interface RunbookRow {
  kind: RunbookKind;
  name: string;
  title: string;
  /** The runbook file (opened with View). */
  file: string;
  /** Where its result is saved. */
  output: string;
  lastRun: string | null;
  /** Text runbooks: the prompt and its header fields in short. */
  detail?: string;
  extra?: string;
}

/** Both kinds in one list, by title. */
export function runbookRows(runbooks: RunbookItem[], texts: FetchItem[]): RunbookRow[] {
  const rows: RunbookRow[] = [
    ...runbooks.map((r) => ({ kind: "json" as const, name: r.name, title: r.title, file: r.path, output: r.output, lastRun: r.lastRun })),
    ...texts.map((t) => ({ kind: "text" as const, name: t.name, title: t.name, file: t.promptPath, output: t.output, lastRun: t.fetchedAt, detail: t.prompt, extra: webSummary(t) || undefined })),
  ];
  return rows.sort((a, b) => a.title.localeCompare(b.title));
}

/**
 * Runbooks: repeatable prompts that each run in a fresh Copilot chat and save their result in
 * Runbooks/Exports/ (earlier results in .streamhub/History/). A text answer is saved as Markdown;
 * checked JSON is validated against the runbook's shape. One set of buttons for both.
 */
export function RunbooksPanel({
  runbooks,
  texts,
  templates,
  busy,
  onCreate,
  onCreateText,
  onRun,
  onOpen,
  onAttach,
  onSchedule,
}: {
  runbooks: RunbookItem[];
  texts: FetchItem[];
  templates: RunbookTemplate[];
  busy: boolean;
  onCreate: (template: string, name: string) => Promise<void>;
  onCreateText: (name: string, prompt: string, web: FetchWeb) => Promise<void>;
  onRun: (kind: RunbookKind, name: string) => void;
  onOpen: (path: string) => void;
  onAttach: (path: string) => void;
  onSchedule?: (kind: RunbookKind, name: string) => void;
}) {
  const [adding, setAdding] = useState(false);
  const [choice, setChoice] = useState("text");
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const rows = runbookRows(runbooks, texts);

  const create = async () => {
    setSaving(true);
    setError("");
    try {
      await onCreate(choice, name);
      setName("");
      setAdding(false);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-2">
      <InfoNote
        details={
          <>
            <p>
              Each runs in a fresh Copilot chat and gives a <em>text answer</em> (saved as Markdown) or <em>checked JSON</em> (checked against the shape the runbook describes).
            </p>
            <p>
              Files in <span className="font-mono">Runbooks/</span>, results in <span className="font-mono">Runbooks/Exports/</span>, earlier results in{" "}
              <span className="font-mono">.streamhub/History/</span>.
            </p>
          </>
        }
      >
        Saved prompts you can run again.
      </InfoNote>

      {adding ? (
        <div className="space-y-2 rounded-lg border border-black/10 p-2 dark:border-white/10">
          <select aria-label="Kind of runbook" className={field} onChange={(e) => setChoice(e.target.value)} value={choice}>
            <option value="text">Text answer (Markdown)</option>
            <optgroup label="Checked JSON, from a template">
              {templates.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.title}
                </option>
              ))}
            </optgroup>
          </select>
          {choice === "text" ? (
            <TextRunbookForm onCancel={() => setAdding(false)} onSave={onCreateText} />
          ) : (
            <>
              <input aria-label="Runbook name" className={field} onChange={(e) => setName(e.target.value)} placeholder="Name, e.g. meetings next week" value={name} />
              {error && <p className="text-rose-600 text-xs dark:text-rose-400">{error}</p>}
              <div className="flex justify-end gap-1">
                <button className={flatButton} onClick={() => setAdding(false)} type="button">
                  Cancel
                </button>
                <button className={cn(flatButton, "bg-black/5 dark:bg-white/10")} disabled={saving || !name.trim()} onClick={create} type="button">
                  {saving ? "Creating..." : "Create"}
                </button>
              </div>
            </>
          )}
        </div>
      ) : (
        <button className={cn(flatButton, "w-full justify-center border border-black/10 py-1.5 dark:border-white/10")} onClick={() => setAdding(true)} type="button">
          <Plus className="h-3.5 w-3.5" /> New runbook
        </button>
      )}

      {rows.map((r) => (
        <div className="rounded-lg border border-black/10 p-2 dark:border-white/10" key={`${r.kind}:${r.name}`}>
          <div className="flex items-center gap-2">
            <span className="truncate font-medium text-sm" title={r.file}>
              {r.title}
            </span>
            <span className="shrink-0 rounded-full border border-black/15 px-1.5 text-[10px] text-muted-foreground dark:border-white/20" title={r.kind === "json" ? "Saves JSON checked against the runbook's shape" : "Saves Copilot's answer as Markdown"}>
              {r.kind === "json" ? "JSON" : "text"}
            </span>
            <span className="ml-auto shrink-0 text-muted-foreground text-xs" title={r.lastRun ? new Date(r.lastRun).toLocaleString() : undefined}>
              {r.lastRun ? fetchedAge(r.lastRun).replace("fetched", "run") : "never run"}
            </span>
          </div>
          {r.detail && (
            <p className="mt-0.5 line-clamp-2 text-muted-foreground text-xs" title={r.detail}>
              {r.detail}
            </p>
          )}
          {r.extra && <p className="mt-0.5 truncate font-mono text-[11px] text-muted-foreground">{r.extra}</p>}
          <div className="mt-0.5 truncate font-mono text-muted-foreground text-xs" title={r.output}>
            {r.output}
          </div>
          <div className="mt-1.5 flex flex-wrap gap-1">
            <button className={flatButton} onClick={() => onRun(r.kind, r.name)} title={busy ? "Add it to the queue; the result is saved when it runs" : "Run it now in a fresh Copilot chat and save the result"} type="button">
              <Play className="h-3 w-3" /> Run
            </button>
            {onSchedule && (
              <button className={flatButton} onClick={() => onSchedule(r.kind, r.name)} title="Run it on set days and times" type="button">
                <CalendarClock className="h-3 w-3" /> Schedule
              </button>
            )}
            <button className={flatButton} onClick={() => onOpen(r.file)} title={`View the runbook (${r.file}); edit it in the project folder`} type="button">
              <FileCode2 className="h-3 w-3" /> View
            </button>
            <button className={flatButton} disabled={!r.lastRun} onClick={() => onOpen(r.output)} title={r.lastRun ? `View the latest result (${r.output})` : "Not run yet"} type="button">
              <FileText className="h-3 w-3" /> Result
            </button>
            <button className={flatButton} disabled={!r.lastRun} onClick={() => onAttach(r.output)} title={r.lastRun ? `Attach @${r.output} to your message` : "Not run yet"} type="button">
              <AtSign className="h-3 w-3" /> Attach
            </button>
          </div>
        </div>
      ))}
      {rows.length === 0 && !adding && <p className="text-muted-foreground text-xs">No runbooks yet.</p>}
    </div>
  );
}
