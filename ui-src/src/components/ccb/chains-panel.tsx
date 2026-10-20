import { InfoNote } from "./info-note";
import { editPlace } from "./runbooks-panel";
import { AlertTriangle, ArrowDown, ArrowUp, CalendarClock, FileCode2, Play, Plus, X } from "lucide-react";
import { useState } from "react";
import type { ChainItem, ChainStep } from "@/lib/api";
import { canAddStep, runTitle, stepCount, stepText, stepToAdd } from "@/lib/chains";
import { cn } from "@/lib/utils";

export { stepText } from "@/lib/chains";

const flatButton =
  "kit-btn kit-btn--ghost kit-btn--sm";
const field =
  "kit-input h-8 min-h-8 w-full";
const smallField = cn(field, "py-0.5 text-xs");
const iconButton = "kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm disabled:opacity-30";

type RunbookName = { name: string; title: string };
type OnSteps = (name: string, op: "add" | "remove" | "up" | "down", opts?: { kind?: "runbook" | "script" | "download"; target?: string; args?: string; index?: number }) => Promise<void>;

/** Runs an async action with a saving flag and its error message; `done` runs after it succeeds. */
function useSaving() {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const run = async (action: () => Promise<void>, done: () => void) => {
    setSaving(true);
    setError("");
    try {
      await action();
      done();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };
  return { saving, error, run };
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
  runbookNames?: RunbookName[];
  /** Change a chain's steps; resolves when done (the list reloads), rejects with the reason. */
  onSteps?: OnSteps;
  busy: boolean;
  onCreate: (name: string) => Promise<void>;
  onRun: (name: string) => void;
  onOpen: (path: string) => void;
  onSchedule?: (name: string) => void;
}) {
  const [adding, setAdding] = useState(false);
  // Kept here, not in the form: Cancel and New chain again shows the name and error as they were.
  const [name, setName] = useState("");
  const saving = useSaving();
  const create = () =>
    saving.run(
      () => onCreate(name),
      () => {
        setName("");
        setAdding(false);
      },
    );

  return (
    <div className="space-y-2">
      <InfoNote
        details={
          <>
            <p>For example an export, then a script that converts it, then a runbook that summarises the result.</p>
            <p>
              Each chain is a file <span className="font-mono">Runbooks/NAME.chain.md</span> with one step per line; edit it there.
            </p>
            <p>A script is approved the first time it runs and again after it changes.</p>
          </>
        }
      >
        Runbooks and scripts that run one after another.
      </InfoNote>

      {adding ? (
        <NewChainForm error={saving.error} name={name} onClose={() => setAdding(false)} onCreate={create} saving={saving.saving} setName={setName} />
      ) : (
        <button className={cn(flatButton, "w-full justify-center border border-(--kit-border) py-1.5")} onClick={() => setAdding(true)} type="button">
          <Plus className="h-3.5 w-3.5" /> New chain
        </button>
      )}

      {chains.map((c) => (
        <ChainCard busy={busy} chain={c} key={c.name} onOpen={onOpen} onRun={onRun} onSchedule={onSchedule} onSteps={onSteps} runbooks={runbookNames} scripts={scripts} />
      ))}
      {chains.length === 0 && !adding && <p className="kit-empty py-3 text-xs">No chains yet.</p>}
    </div>
  );
}

/** The name field of a new chain, with Cancel and Create. */
function NewChainForm({
  name,
  setName,
  saving,
  error,
  onCreate,
  onClose,
}: {
  name: string;
  setName: (name: string) => void;
  saving: boolean;
  error: string;
  onCreate: () => void;
  onClose: () => void;
}) {
  return (
    <div className="kit-panel space-y-2 p-2">
      <input aria-label="Chain name" className={field} onChange={(e) => setName(e.target.value)} placeholder="Name, e.g. weekly report" value={name} />
      {error && <p className="kit-error-text">{error}</p>}
      <div className="flex justify-end gap-1">
        <button className={flatButton} onClick={onClose} type="button">
          Cancel
        </button>
        <button className={cn(flatButton, "bg-(--kit-surface-2)")} disabled={saving || !name.trim()} onClick={onCreate} type="button">
          {saving ? "Creating..." : "Create"}
        </button>
      </div>
    </div>
  );
}

/** One chain: its title, steps (with move and remove), the add-step form, problems and its buttons. */
function ChainCard({
  chain: c,
  busy,
  runbooks,
  scripts,
  onSteps,
  onRun,
  onOpen,
  onSchedule,
}: {
  chain: ChainItem;
  busy: boolean;
  runbooks: RunbookName[];
  scripts: string[];
  onSteps?: OnSteps;
  onRun: (name: string) => void;
  onOpen: (path: string) => void;
  onSchedule?: (name: string) => void;
}) {
  const blocked = c.problems.length > 0;
  return (
    <div className="kit-panel p-2">
      <div className="flex items-center gap-2">
        <span className="truncate font-medium text-sm" title={c.path}>
          {c.title}
        </span>
        {c.shared && (
          <span className="kit-badge min-h-0 shrink-0 py-px text-[10px]" title="From the library beside the projects: every project in this folder can run it">
            shared
          </span>
        )}
        <span className="ml-auto shrink-0 text-muted-foreground text-xs">{stepCount(c.steps.length)}</span>
      </div>
      <ol className="mt-1 space-y-0.5 text-muted-foreground text-xs">
        {c.steps.map((s, i) => (
          <StepRow index={i} key={`${i}-${s.kind}-${s.target}`} last={i === c.steps.length - 1} onChange={onSteps && ((op) => onSteps(c.name, op, { index: i }))} step={s} />
        ))}
      </ol>
      {onSteps && <AddStep chain={c.name} onSteps={onSteps} runbooks={runbooks} scripts={scripts} />}
      {/* A new chain has no steps yet: that is not a problem to warn about, just the next step. */}
      {c.steps.length === 0 && <p className="mt-1 text-muted-foreground text-xs">No steps yet: pick a runbook or script above and click Add.</p>}
      {c.steps.length > 0 && blocked && (
        <div className="mt-1 flex gap-1 text-xs text-foreground/80">
          <AlertTriangle aria-hidden className="mt-0.5 h-3 w-3 shrink-0" />
          <span>{c.problems.join("; ")}</span>
        </div>
      )}
      <div className="mt-1.5 flex flex-wrap gap-1">
        <button className={flatButton} disabled={blocked} onClick={() => onRun(c.name)} title={runTitle(c, busy)} type="button">
          <Play className="h-3 w-3" /> Run
        </button>
        {onSchedule && (
          <button className={flatButton} disabled={blocked} onClick={() => onSchedule(c.name)} title="Run it on set days and times" type="button">
            <CalendarClock className="h-3 w-3" /> Schedule
          </button>
        )}
        <button className={flatButton} onClick={() => onOpen(c.path)} title={`View the chain (${c.path}); ${editPlace(c.path, c.shared)}`} type="button">
          <FileCode2 className="h-3 w-3" /> View
        </button>
      </div>
    </div>
  );
}

/** One numbered step, with Move up, Move down and Remove when the steps can be changed. */
function StepRow({ step, index, last, onChange }: { step: ChainStep; index: number; last: boolean; onChange?: (op: "up" | "down" | "remove") => void }) {
  const text = stepText(step);
  return (
    <li className="group flex items-center gap-1">
      <span className="min-w-0 flex-1 truncate font-mono" title={text}>
        {index + 1}. {text}
      </span>
      {onChange && (
        <span className="flex shrink-0 gap-0.5 opacity-60 group-hover:opacity-100">
          <button aria-label="Move up" className={iconButton} disabled={index === 0} onClick={() => onChange("up")} title="Move this step up" type="button">
            <ArrowUp className="h-3 w-3" />
          </button>
          <button aria-label="Move down" className={iconButton} disabled={last} onClick={() => onChange("down")} title="Move this step down" type="button">
            <ArrowDown className="h-3 w-3" />
          </button>
          <button aria-label="Remove step" className={iconButton} onClick={() => onChange("remove")} title="Remove this step from the chain" type="button">
            <X className="h-3 w-3" />
          </button>
        </span>
      )}
    </li>
  );
}

/** Adds a runbook, a script from Scripts/ or a download from SharePoint/OneDrive as the chain's last step. */
function AddStep({ chain, runbooks, scripts, onSteps }: { chain: string; runbooks: RunbookName[]; scripts: string[]; onSteps: OnSteps }) {
  const [pick, setPick] = useState("");
  const [args, setArgs] = useState("");
  const [link, setLink] = useState("");
  const { saving, error, run } = useSaving();
  const add = () =>
    run(
      () => onSteps(chain, "add", stepToAdd(pick, args, link)),
      () => {
        setPick("");
        setArgs("");
        setLink("");
      },
    );
  return (
    <div className="mt-1.5 space-y-1">
      <div className="flex gap-1">
        <StepSelect onPick={setPick} pick={pick} runbooks={runbooks} scripts={scripts} />
        <button className={cn(flatButton, "shrink-0 border border-(--kit-border)")} disabled={!canAddStep(pick, link, saving)} onClick={add} type="button">
          <Plus className="h-3 w-3" /> Add
        </button>
      </div>
      {pick.startsWith("script:") && <input aria-label="Script arguments" className={smallField} onChange={(e) => setArgs(e.target.value)} placeholder="Optional arguments, e.g. -Week current" value={args} />}
      {pick === "download:" && <DownloadFields args={args} link={link} setArgs={setArgs} setLink={setLink} />}
      {!runbooks.length && !scripts.length && <p className="text-muted-foreground text-xs">No runbooks or scripts yet: create a runbook above, or put a script in Scripts/.</p>}
      {error && <p className="kit-error-text">{error}</p>}
    </div>
  );
}

/** The list of what a step can run: runbooks, scripts in Scripts/ and a download. */
function StepSelect({ pick, onPick, runbooks, scripts }: { pick: string; onPick: (value: string) => void; runbooks: RunbookName[]; scripts: string[] }) {
  return (
    <select aria-label="Step to add" className={smallField} onChange={(e) => onPick(e.target.value)} value={pick}>
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
      <optgroup label="Microsoft 365">
        <option value="download:">Download a file from SharePoint or OneDrive</option>
      </optgroup>
    </select>
  );
}

/** A download step's link and where it is saved. */
function DownloadFields({ link, setLink, args, setArgs }: { link: string; setLink: (v: string) => void; args: string; setArgs: (v: string) => void }) {
  return (
    <>
      <input aria-label="Link to the file" className={smallField} onChange={(e) => setLink(e.target.value)} placeholder="Link to the file (SharePoint or OneDrive, https://...)" value={link} />
      <input aria-label="Save as" className={smallField} onChange={(e) => setArgs(e.target.value)} placeholder="Save as, e.g. Downloads/sales.csv (empty: Downloads/ with the file's own name)" value={args} />
      <p className="text-muted-foreground text-xs">StreamHub's Edge fetches it with your Microsoft 365 sign-in each time the chain runs. You approve each link once.</p>
    </>
  );
}
