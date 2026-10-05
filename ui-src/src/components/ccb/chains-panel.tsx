import { AlertTriangle, ArrowDown, ArrowUp, CalendarClock, FileCode2, Play, Plus, X } from "lucide-react";
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

/** Chains: runbooks and scripts from Scripts/ that run one after another. */
export function ChainsPanel({
  chains,
  scripts,
  busy,
  onCreate,
  onRun,
  onOpen,
  onSchedule,
  runbookNames = [],
  onSteps,
}: {
  chains: ChainItem[];
  scripts: string[];
  /** Runbooks a step can run (both kinds). */
  runbookNames?: { name: string; title: string }[];
  /** Change a chain's steps; resolves when done (the list reloads), rejects with the reason. */
  onSteps?: (name: string, op: "add" | "remove" | "up" | "down", opts?: { kind?: "runbook" | "script"; target?: string; args?: string; index?: number }) => Promise<void>;
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
        Runbooks and scripts from <span className="font-mono">Scripts/</span> that run one after another, for example an export, then a script that
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
              <li className="group flex items-center gap-1" key={`${i}-${s.kind}-${s.target}`}>
                <span className="min-w-0 flex-1 truncate font-mono" title={stepText(s)}>
                  {i + 1}. {stepText(s)}
                </span>
                {onSteps && (
                  <span className="flex shrink-0 gap-0.5 opacity-60 group-hover:opacity-100">
                    <button aria-label="Move up" className={iconButton} disabled={i === 0} onClick={() => onSteps(c.name, "up", { index: i })} title="Move this step up" type="button">
                      <ArrowUp className="h-3 w-3" />
                    </button>
                    <button aria-label="Move down" className={iconButton} disabled={i === c.steps.length - 1} onClick={() => onSteps(c.name, "down", { index: i })} title="Move this step down" type="button">
                      <ArrowDown className="h-3 w-3" />
                    </button>
                    <button aria-label="Remove step" className={iconButton} onClick={() => onSteps(c.name, "remove", { index: i })} title="Remove this step from the chain" type="button">
                      <X className="h-3 w-3" />
                    </button>
                  </span>
                )}
              </li>
            ))}
          </ol>
          {onSteps && <AddStep chain={c.name} onSteps={onSteps} runbooks={runbookNames} scripts={scripts} />}
          {/* A new chain has no steps yet: that is not a problem to warn about, just the next step. */}
          {c.steps.length === 0 && <p className="mt-1 text-muted-foreground text-xs">No steps yet: pick a runbook or script above and click Add.</p>}
          {c.steps.length > 0 && c.problems.length > 0 && (
            <div className="mt-1 flex gap-1 text-xs text-foreground/80">
              <AlertTriangle aria-hidden className="mt-0.5 h-3 w-3 shrink-0" />
              <span>{c.problems.join("; ")}</span>
            </div>
          )}
          <div className="mt-1.5 flex flex-wrap gap-1">
            <button
              className={flatButton}
              disabled={c.problems.length > 0}
              onClick={() => onRun(c.name)}
              title={c.steps.length === 0 ? "Add a step first" : c.problems.length ? "Fix the steps first" : busy ? "Add it to the queue" : "Run the steps now, one after another"}
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
              <FileCode2 className="h-3 w-3" /> View
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

const iconButton = "rounded p-0.5 hover:bg-black/5 hover:text-foreground disabled:opacity-30 disabled:hover:bg-transparent dark:hover:bg-white/5";

/** Adds a runbook or a script from Scripts/ as the chain's last step. */
function AddStep({
  chain,
  runbooks,
  scripts,
  onSteps,
}: {
  chain: string;
  runbooks: { name: string; title: string }[];
  scripts: string[];
  onSteps: NonNullable<Parameters<typeof ChainsPanel>[0]["onSteps"]>;
}) {
  const [pick, setPick] = useState("");
  const [args, setArgs] = useState("");
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const isScript = pick.startsWith("script:");
  const add = async () => {
    setSaving(true);
    setError("");
    try {
      const target = pick.slice(pick.indexOf(":") + 1);
      await onSteps(chain, "add", { kind: isScript ? "script" : "runbook", target, args: isScript ? args : "" });
      setPick("");
      setArgs("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };
  return (
    <div className="mt-1.5 space-y-1">
      <div className="flex gap-1">
        <select aria-label="Step to add" className={cn(field, "py-0.5 text-xs")} onChange={(e) => setPick(e.target.value)} value={pick}>
          <option value="">Add a step...</option>
          {runbooks.length > 0 && (
            <optgroup label="Runbooks">
              {runbooks.map((r) => (
                <option key={r.name} value={`runbook:${r.name}`}>
                  {r.title}
                </option>
              ))}
            </optgroup>
          )}
          {scripts.length > 0 && (
            <optgroup label="Scripts in Scripts/">
              {scripts.map((p) => (
                <option key={p} value={`script:${p}`}>
                  {p.replace(/^Scripts\//i, "")}
                </option>
              ))}
            </optgroup>
          )}
        </select>
        <button className={cn(flatButton, "shrink-0 border border-black/10 dark:border-white/10")} disabled={!pick || saving} onClick={add} type="button">
          <Plus className="h-3 w-3" /> Add
        </button>
      </div>
      {isScript && (
        <input aria-label="Script arguments" className={cn(field, "py-0.5 text-xs")} onChange={(e) => setArgs(e.target.value)} placeholder="Optional arguments, e.g. -Week current" value={args} />
      )}
      {!runbooks.length && !scripts.length && <p className="text-muted-foreground text-xs">No runbooks or scripts yet: create a runbook above, or put a script in Scripts/.</p>}
      {error && <p className="text-rose-600 text-xs dark:text-rose-400">{error}</p>}
    </div>
  );
}
