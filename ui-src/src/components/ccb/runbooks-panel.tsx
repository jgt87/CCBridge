import { AtSign, CalendarClock, FileCode2, FileText, Play, Plus } from "lucide-react";
import { InfoNote } from "./info-note";
import { useState } from "react";
import type { FetchItem, FetchWeb, RunbookItem, RunbookTemplate } from "@/lib/api";
import { attachTitle, kindBadge, lastRunLabel, resultTitle, runTitle } from "@/lib/runbook-labels";
import { cn } from "@/lib/utils";
import { fetchedAge, TextRunbookForm, webSummary } from "./fetch-panel";

const flatButton =
  "kit-btn kit-btn--ghost kit-btn--sm";
const field =
  "kit-input h-8 min-h-8 w-full";

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
  /** From the library beside the projects: every project in the folder can run it; edited there. */
  shared?: boolean;
}

/** Where a runbook, chain or script file is edited: the project folder, or the library beside the projects. */
export function editPlace(file: string, shared?: boolean): string {
  return shared || /^(shared|library|shared-library)\//i.test(file) ? "shared by every project in this folder; edit it in the .streamhub folder beside the projects" : "edit it in the project folder";
}

/** Both kinds in one list, by title. */
export function runbookRows(runbooks: RunbookItem[], texts: FetchItem[]): RunbookRow[] {
  const rows: RunbookRow[] = [
    ...runbooks.map((r) => ({ kind: "json" as const, name: r.name, title: r.title, file: r.path, output: r.output, lastRun: r.lastRun, shared: r.shared })),
    ...texts.map((t) => ({ kind: "text" as const, name: t.name, title: t.name, file: t.promptPath, output: t.output, lastRun: t.fetchedAt, detail: t.prompt, extra: webSummary(t) || undefined, shared: t.shared })),
  ];
  return rows.sort((a, b) => a.title.localeCompare(b.title));
}

/** The badges after the title: the kind of answer, and shared for the library beside the projects. */
function RunbookBadges({ row }: { row: RunbookRow }) {
  const badge = kindBadge(row.kind);
  return (
    <>
      <span className="kit-badge min-h-0 shrink-0 py-px text-[10px]" title={badge.title}>
        {badge.text}
      </span>
      {row.shared && (
        <span className="kit-badge min-h-0 shrink-0 py-px text-[10px]" title="From the library beside the projects: every project in this folder can run it">
          shared
        </span>
      )}
    </>
  );
}

/** Run, Schedule, View, Result and Attach: one set of buttons for both kinds. */
function RunbookActions({
  row,
  busy,
  onRun,
  onOpen,
  onAttach,
  onSchedule,
}: {
  row: RunbookRow;
  busy: boolean;
  onRun: (kind: RunbookKind, name: string) => void;
  onOpen: (path: string) => void;
  onAttach: (path: string) => void;
  onSchedule?: (kind: RunbookKind, name: string) => void;
}) {
  const r = row;
  return (
    <div className="mt-1.5 flex flex-wrap gap-1">
      <button className={flatButton} onClick={() => onRun(r.kind, r.name)} title={runTitle(busy)} type="button">
        <Play className="h-3 w-3" /> Run
      </button>
      {onSchedule && (
        <button className={flatButton} onClick={() => onSchedule(r.kind, r.name)} title="Run it on set days and times" type="button">
          <CalendarClock className="h-3 w-3" /> Schedule
        </button>
      )}
      <button className={flatButton} onClick={() => onOpen(r.file)} title={`View the runbook (${r.file}); ${editPlace(r.file, r.shared)}`} type="button">
        <FileCode2 className="h-3 w-3" /> View
      </button>
      <button className={flatButton} disabled={!r.lastRun} onClick={() => onOpen(r.output)} title={resultTitle(r.lastRun, r.output)} type="button">
        <FileText className="h-3 w-3" /> Result
      </button>
      <button className={flatButton} disabled={!r.lastRun} onClick={() => onAttach(r.output)} title={attachTitle(r.lastRun, r.output)} type="button">
        <AtSign className="h-3 w-3" /> Attach
      </button>
    </div>
  );
}

/** One runbook: title, badges, when it last ran, its prompt (text runbooks), where the result goes, and its buttons. */
function RunbookCard({ row, ...actions }: { row: RunbookRow } & Omit<Parameters<typeof RunbookActions>[0], "row">) {
  const r = row;
  return (
    <div className="kit-panel p-2">
      <div className="flex items-center gap-2">
        <span className="truncate font-medium text-sm" title={r.file}>
          {r.title}
        </span>
        <RunbookBadges row={r} />
        <span className="ml-auto shrink-0 text-muted-foreground text-xs" title={r.lastRun ? new Date(r.lastRun).toLocaleString() : undefined}>
          {lastRunLabel(r.lastRun, fetchedAge)}
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
      <RunbookActions row={r} {...actions} />
    </div>
  );
}

/** The name and buttons for a checked-JSON runbook made from a template. */
function TemplateRunbookForm({
  name,
  setName,
  saving,
  error,
  onCreate,
  onCancel,
}: {
  name: string;
  setName: (name: string) => void;
  saving: boolean;
  error: string;
  onCreate: () => void;
  onCancel: () => void;
}) {
  return (
    <>
      <input aria-label="Runbook name" className={field} onChange={(e) => setName(e.target.value)} placeholder="Name, e.g. meetings next week" value={name} />
      {error && <p className="kit-error-text">{error}</p>}
      <div className="flex justify-end gap-1">
        <button className={flatButton} onClick={onCancel} type="button">
          Cancel
        </button>
        <button className={cn(flatButton, "bg-(--kit-surface-2)")} disabled={saving || !name.trim()} onClick={onCreate} type="button">
          {saving ? "Creating..." : "Create"}
        </button>
      </div>
    </>
  );
}

/** New runbook: the button, or the form with the kind (text answer or a template) once it is open. */
function NewRunbook({
  adding,
  setAdding,
  templates,
  onCreate,
  onCreateText,
}: {
  adding: boolean;
  setAdding: (adding: boolean) => void;
  templates: RunbookTemplate[];
  onCreate: (template: string, name: string) => Promise<void>;
  onCreateText: (name: string, prompt: string, web: FetchWeb) => Promise<void>;
}) {
  // Kept while the form is closed, as before: reopening it shows the last kind and name.
  const [choice, setChoice] = useState("text");
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

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

  if (!adding) {
    return (
      <button className={cn(flatButton, "w-full justify-center border border-(--kit-border) py-1.5")} onClick={() => setAdding(true)} type="button">
        <Plus className="h-3.5 w-3.5" /> New runbook
      </button>
    );
  }
  return (
    <div className="kit-panel space-y-2 p-2">
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
        <TemplateRunbookForm error={error} name={name} onCancel={() => setAdding(false)} onCreate={create} saving={saving} setName={setName} />
      )}
    </div>
  );
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
  const rows = runbookRows(runbooks, texts);

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

      <NewRunbook adding={adding} onCreate={onCreate} onCreateText={onCreateText} setAdding={setAdding} templates={templates} />

      {rows.map((r) => (
        <RunbookCard busy={busy} key={`${r.kind}:${r.name}`} onAttach={onAttach} onOpen={onOpen} onRun={onRun} onSchedule={onSchedule} row={r} />
      ))}
      {rows.length === 0 && !adding && <p className="kit-empty py-3 text-xs">No runbooks yet.</p>}
    </div>
  );
}
