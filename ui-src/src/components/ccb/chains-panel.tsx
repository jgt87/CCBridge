import { AlertTriangle, CalendarClock, FileCode2, Play, Plus } from "lucide-react";
import { useState } from "react";
import type { ChainItem, ChainStep } from "@/lib/api";
import { cn } from "@/lib/utils";

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";
const field =
  "w-full rounded-md border border-black/10 bg-transparent px-2 py-1 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30";

/** One step as a short line: "runbook meetings", "script Scripts/x.ps1 -Week 1", "runbook summary + 1 file". */
export function stepText(s: ChainStep): string {
  const extra = s.kind === "script" && s.args ? ` ${s.args}` : s.kind === "runbook" && s.with?.length ? ` + ${s.with.length} file${s.with.length === 1 ? "" : "s"}` : "";
  return `${s.kind} ${s.target}${extra}`;
}

/** Chains: runbooks, fetch prompts and scripts from Scripts/ that run one after another. */
export function ChainsPanel({
  chains,
  scripts,
  busy,
  onCreate,
  onRun,
  onOpen,
  onSchedule,
}: {
  chains: ChainItem[];
  scripts: string[];
  busy: boolean;
  onCreate: (name: string) => Promise<void>;
  onRun: (name: string) => void;
  onOpen: (path: string) => void;
  onSchedule?: (name: string) => void;
}) {
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  const create = async () => {
    setSaving(true);
    setError("");
    try {
      await onCreate(name);
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
      <p className="text-muted-foreground text-xs">
        Runbooks, fetch prompts and scripts from <span className="font-mono">Scripts/</span> that run one after another, for example an export, then a script that
        converts it, then a runbook that summarises the result. Each chain is a file <span className="font-mono">Runbooks/NAME.chain.md</span> with one step per line; edit it there.
        A script is approved the first time it runs and again after it changes.
      </p>

      {adding ? (
        <div className="space-y-2 rounded-lg border border-black/10 p-2 dark:border-white/10">
          <input aria-label="Chain name" className={field} onChange={(e) => setName(e.target.value)} placeholder="Name, e.g. weekly report" value={name} />
          {error && <p className="text-rose-600 text-xs dark:text-rose-400">{error}</p>}
          <div className="flex justify-end gap-1">
            <button className={flatButton} onClick={() => setAdding(false)} type="button">
              Cancel
            </button>
            <button className={cn(flatButton, "bg-black/5 dark:bg-white/10")} disabled={saving || !name.trim()} onClick={create} type="button">
              {saving ? "Creating..." : "Create"}
            </button>
          </div>
        </div>
      ) : (
        <button className={cn(flatButton, "w-full justify-center border border-black/10 py-1.5 dark:border-white/10")} onClick={() => setAdding(true)} type="button">
          <Plus className="h-3.5 w-3.5" /> New chain
        </button>
      )}

      {chains.map((c) => (
        <div className="rounded-lg border border-black/10 p-2 dark:border-white/10" key={c.name}>
          <div className="flex items-center gap-2">
            <span className="truncate font-medium text-sm" title={c.path}>
              {c.title}
            </span>
            <span className="ml-auto shrink-0 text-muted-foreground text-xs">
              {c.steps.length} step{c.steps.length === 1 ? "" : "s"}
            </span>
          </div>
          <ol className="mt-1 space-y-0.5 text-muted-foreground text-xs">
            {c.steps.map((s, i) => (
              <li className="truncate font-mono" key={`${i}-${s.kind}-${s.target}`} title={stepText(s)}>
                {i + 1}. {stepText(s)}
              </li>
            ))}
          </ol>
          {c.problems.length > 0 && (
            <div className="mt-1 flex gap-1 text-xs text-zinc-700 dark:text-zinc-300">
              <AlertTriangle aria-hidden className="mt-0.5 h-3 w-3 shrink-0" />
              <span>{c.problems.join("; ")}</span>
            </div>
          )}
          <div className="mt-1.5 flex flex-wrap gap-1">
            <button
              className={flatButton}
              disabled={c.problems.length > 0}
              onClick={() => onRun(c.name)}
              title={c.problems.length ? "Fix the steps first" : busy ? "Add it to the queue" : "Run the steps now, one after another"}
              type="button"
            >
              <Play className="h-3 w-3" /> Run
            </button>
            {onSchedule && (
              <button className={flatButton} disabled={c.problems.length > 0} onClick={() => onSchedule(c.name)} title="Run it on set days and times" type="button">
                <CalendarClock className="h-3 w-3" /> Schedule
              </button>
            )}
            <button className={flatButton} onClick={() => onOpen(c.path)} title={`View the chain (${c.path}); edit it in the project folder`} type="button">
              <FileCode2 className="h-3 w-3" /> Chain
            </button>
          </div>
        </div>
      ))}
      {chains.length === 0 && !adding && <p className="text-muted-foreground text-sm">No chains yet.</p>}
      {scripts.length > 0 && (
        <p className="text-muted-foreground text-xs" title={scripts.join("\n")}>
          Scripts a chain can run: {scripts.length} in <span className="font-mono">Scripts/</span>.
        </p>
      )}
    </div>
  );
}
