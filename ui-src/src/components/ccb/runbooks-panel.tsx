import { AtSign, FileCode2, FileText, Plus, Play } from "lucide-react";
import { useState } from "react";
import type { RunbookItem, RunbookTemplate } from "@/lib/api";
import { cn } from "@/lib/utils";
import { fetchedAge } from "./fetch-panel";

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";
const field =
  "w-full rounded-md border border-black/10 bg-transparent px-2 py-1 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30";

/** Runbooks: repeatable read-only exports of Microsoft 365 data to JSON, from a template. */
export function RunbooksPanel({
  runbooks,
  templates,
  busy,
  onCreate,
  onRun,
  onOpen,
  onAttach,
}: {
  runbooks: RunbookItem[];
  templates: RunbookTemplate[];
  busy: boolean;
  onCreate: (template: string, name: string) => Promise<void>;
  onRun: (name: string) => void;
  onOpen: (path: string) => void;
  onAttach: (path: string) => void;
}) {
  const [adding, setAdding] = useState(false);
  const [template, setTemplate] = useState("");
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const chosen = template || templates[0]?.id || "";

  const create = async () => {
    setSaving(true);
    setError("");
    try {
      await onCreate(chosen, name);
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
      <div className="font-medium text-sm">Runbooks</div>
      <p className="text-muted-foreground text-xs">
        Repeatable, read-only exports of Microsoft 365 data to JSON. Each runbook is a file in <span className="font-mono">runbooks/</span> with the sources, period, JSON
        shape and rules; edit it there. Results are checked and saved in <span className="font-mono">exports/</span>.
      </p>

      {adding ? (
        <div className="space-y-2 rounded-lg border border-black/10 p-2 dark:border-white/10">
          <select className={field} onChange={(e) => setTemplate(e.target.value)} value={chosen}>
            {templates.map((t) => (
              <option key={t.id} value={t.id}>
                {t.title}
              </option>
            ))}
          </select>
          <input className={field} onChange={(e) => setName(e.target.value)} placeholder="Name, e.g. meetings next week" value={name} />
          {error && <p className="text-rose-600 text-xs dark:text-rose-400">{error}</p>}
          <div className="flex justify-end gap-1">
            <button className={flatButton} onClick={() => setAdding(false)} type="button">
              Cancel
            </button>
            <button className={cn(flatButton, "bg-black/5 dark:bg-white/10")} disabled={saving || !name.trim() || !chosen} onClick={create} type="button">
              {saving ? "Creating..." : "Create"}
            </button>
          </div>
        </div>
      ) : (
        <button className={cn(flatButton, "w-full justify-center border border-black/10 py-1.5 dark:border-white/10")} onClick={() => setAdding(true)} type="button">
          <Plus className="h-3.5 w-3.5" /> New runbook from a template
        </button>
      )}

      {runbooks.map((rb) => (
        <div className="rounded-lg border border-black/10 p-2 dark:border-white/10" key={rb.name}>
          <div className="flex items-center gap-2">
            <span className="truncate font-medium text-sm" title={rb.path}>
              {rb.title}
            </span>
            <span className="ml-auto shrink-0 text-muted-foreground text-xs" title={rb.lastRun ? new Date(rb.lastRun).toLocaleString() : undefined}>
              {rb.lastRun ? fetchedAge(rb.lastRun).replace("fetched", "run") : "never run"}
            </span>
          </div>
          <div className="mt-0.5 truncate font-mono text-muted-foreground text-xs" title={rb.output}>
            {rb.output}
          </div>
          <div className="mt-1.5 flex flex-wrap gap-1">
            <button className={flatButton} disabled={busy} onClick={() => onRun(rb.name)} title="Run it now (read-only) and save the checked JSON" type="button">
              <Play className="h-3 w-3" /> Run
            </button>
            <button className={flatButton} onClick={() => onOpen(rb.path)} title={`View the runbook (${rb.path}); edit it in the project folder`} type="button">
              <FileCode2 className="h-3 w-3" /> Runbook
            </button>
            <button className={flatButton} disabled={!rb.lastRun} onClick={() => onOpen(rb.output)} title={rb.output} type="button">
              <FileText className="h-3 w-3" /> Result
            </button>
            <button className={flatButton} disabled={!rb.lastRun} onClick={() => onAttach(rb.output)} title={`Attach @${rb.output} to your message`} type="button">
              <AtSign className="h-3 w-3" /> Attach
            </button>
          </div>
        </div>
      ))}
      {runbooks.length === 0 && !adding && <p className="text-muted-foreground text-sm">No runbooks yet.</p>}
    </div>
  );
}
