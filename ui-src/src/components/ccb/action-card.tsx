import {
  AlertTriangle,
  Check,
  ChevronRight,
  FilePen,
  FilePlus2,
  FileSearch,
  FolderInput,
  FolderSearch,
  ListTodo,
  Play,
  Workflow,
  Camera,
  RotateCcw,
  TerminalSquare,
  X,
} from "lucide-react";
import { useMemo, useState } from "react";
import { cardOpen, useCardView } from "@/lib/card-view";
import GradientButton from "@/components/kokonutui/gradient-button";
import HoldButton from "@/components/kokonutui/hold-button";
import { Input } from "@/components/ui/input";
import { api, type ChangeBlock, type Preview } from "@/lib/api";
import { cn } from "@/lib/utils";
import { countChanges, diffLines } from "@/lib/diff";
import { ChangePill } from "./change-pill";
import { ActionOutput } from "./action-output";
import { DiffView } from "./diff-view";
import { TodoView } from "./todo-view";
import { isTodoChange, todoChange } from "@/lib/todo-list";
import { CodeView } from "./code-block";
import { languageForPath } from "@/lib/highlight";
import { formatElapsed, liveLines, parseRunOutput, useRunLive, waitText, type RunLive } from "@/lib/run-live";
import { ConsoleView } from "./console-view";

export interface ActionItem {
  id: string;
  action: string;
  target: string;
  status: string; // running | awaiting | ok | already applied | failed | rejected | skipped | interrupted
  preview?: Preview | null;
  warning?: string | null;
  /** web: what the person can allow from now on when approving (most specific first). */
  allowOptions?: string[];
  error?: string;
  summary?: string;
  output?: string;
  /** Who approved or rejected it: "user" (you, in the web app), "api" or "mcp". */
  decidedBy?: string;
  /** "streamhub": a change StreamHub made itself (data copies, folder moves, links, source data put back). */
  by?: string;
  /** Failed step: category, possible reasons and what happens next. */
  code?: string;
  reasons?: string[];
  next?: string;
  /** A run the person opened in a console window: its output stays in that window. */
  window?: boolean;
}

/** A running command's output as it comes, drawn like a console window. */
export function LiveConsole({ live }: { live: RunLive }) {
  const wait = waitText(live);
  return (
    <ConsoleView
      footer={
        <span>
          {live.label ? `${live.label}: ` : ""}running {formatElapsed(live.elapsed)}
          {wait && <span className="block text-neutral-200">{wait}</span>}
        </span>
      }
      lines={liveLines(live.lines)}
      live
      title={`> ${live.command}`}
    />
  );
}

/** Runs the command again in a real console window, where its questions can be answered. */
function OpenInWindow({ command, strong = false }: { command: string; strong?: boolean }) {
  const [state, setState] = useState<"" | "busy" | "opened" | string>("");
  const open = async () => {
    setState("busy");
    try {
      await api.runInWindow(command);
      setState("opened");
    } catch (e) {
      setState(e instanceof Error ? e.message : "Could not open the window");
    }
  };
  return (
    <div className="flex flex-wrap items-center gap-2 text-xs">
      <button
        className={cn(
          "flex h-8 items-center gap-1.5 rounded-lg px-2.5 hover:bg-(--kit-surface-2)",
          strong ? "border border-(--kit-border-strong) text-foreground" : "text-muted-foreground hover:text-foreground"
        )}
        disabled={state === "busy"}
        onClick={open}
        title="Runs this command in its own console window in the project folder. You can watch it and answer its questions there; StreamHub notes the exit code."
        type="button"
      >
        <TerminalSquare className="h-3.5 w-3.5" /> Open in a window
      </button>
      {state === "opened" && <span className="text-muted-foreground">Opened: see the console window. Its result shows on a new card.</span>}
      {state && state !== "busy" && state !== "opened" && <span className="text-(--kit-error)">{state}</span>}
    </div>
  );
}

const ICONS: Record<string, React.ReactNode> = {
  read: <FileSearch className="h-4 w-4 text-muted-foreground" />,
  glob: <FolderSearch className="h-4 w-4 text-muted-foreground" />,
  grep: <FolderSearch className="h-4 w-4 text-muted-foreground" />,
  write: <FilePlus2 className="h-4 w-4 text-muted-foreground" />,
  edit: <FilePen className="h-4 w-4 text-muted-foreground" />,
  run: <TerminalSquare className="h-4 w-4 text-muted-foreground" />,
  runbook: <Workflow className="h-4 w-4 text-muted-foreground" />,
  screenshot: <Camera className="h-4 w-4 text-muted-foreground" />,
  todo: <ListTodo className="h-4 w-4 text-muted-foreground" />,
  move: <FolderInput className="h-4 w-4 text-muted-foreground" />,
  restore: <RotateCcw className="h-4 w-4 text-muted-foreground" />,
};

const VERBS: Record<string, string> = {
  runbook: "Run runbook",
  screenshot: "Screenshot",
  read: "Read",
  glob: "List",
  grep: "Search",
  write: "Write",
  edit: "Edit",
  run: "Run",
  todo: "Plan",
  move: "Move",
  restore: "Restore",
};

function StatusBadge({ status }: { status: string }) {
  const map: Record<string, string> = {
    running: "text-muted-foreground",
    awaiting: "font-medium text-foreground",
    ok: "text-muted-foreground",
    "already applied": "text-muted-foreground",
    failed: "text-(--kit-error)",
    rejected: "text-muted-foreground",
    skipped: "text-muted-foreground",
    interrupted: "text-muted-foreground",
    ambiguous: "text-muted-foreground",
  };
  const label: Record<string, string> = {
    interrupted: "interrupted (StreamHub restarted)",
    ambiguous: "needs a more exact SEARCH",
    running: "running",
    awaiting: "needs approval",
    ok: "done",
    "already applied": "already applied (verified)",
    failed: "failed",
    rejected: "rejected",
    skipped: "skipped (plan mode)",
  };
  return <span className={cn("text-xs", map[status])}>{label[status] ?? status}</span>;
}

export function ActionCard({ item }: { item: ActionItem }) {
  // null: follow the setting (Settings > This browser > Cards) until the person opens or closes it.
  const [open, setOpen] = useState<boolean | null>(null);
  const view = useCardView();
  const [note, setNote] = useState("");
  const [sent, setSent] = useState(false);
  // Blocks of a change the person unticked: left out when approving (the rest is written).
  const [skip, setSkip] = useState<number[]>([]);
  // web: a part of the site to allow from now on with this approval ("" = only these pages).
  const [allow, setAllow] = useState("");
  const blocks = asBlocks(item.preview?.hunks);
  const awaiting = item.status === "awaiting" && !sent;
  // The command running now: its output as it comes (the card opens to show it).
  const { live, windows } = useRunLive();
  const running = item.status === "running";
  const myLive = item.action === "run" && running && live?.id === item.id ? live : null;
  const myWindow = item.window && running ? windows.find((w) => w.id === item.id) : undefined;
  // Open by default; with auto-collapse a finished step folds up (the reader can still open or close any card).
  const expanded = awaiting || (open ?? (Boolean(myLive) || cardOpen(sent && item.status === "awaiting" ? "running" : item.status, view)));
  const ran = item.action === "run" && item.output ? parseRunOutput(item.output) : null;
  const needsTerminal = /interactive terminal|needs a terminal|RUN-INTERACTIVE/i.test(`${item.output ?? ""} ${item.code ?? ""}`);

  const decide = async (decision: "approve" | "reject") => {
    setSent(true);
    try {
      await api.approve(item.id, decision, note, decision === "approve" ? skip : [], decision === "approve" ? allow : "");
    } catch {
      setSent(false);
    }
  };

  const hasDetails = Boolean(item.preview || item.output || item.error || item.reasons?.length || item.action === "run");
  const counts = useMemo(() => {
    if (!item.preview || item.action === "run") return null;
    const lines = diffLines(item.preview.old ?? "", item.preview.new ?? "");
    return lines ? countChanges(lines) : null;
  }, [item.preview]);
  // A to-do list (TODO.md, or a file of "- [ ]" items): shown as a checklist, not as lines.
  const todo = useMemo(() => {
    const p = item.preview;
    if (!p || item.action === "run" || !isTodoChange(p.path ?? "", p.new ?? "")) return null;
    return todoChange(p.old ?? "", p.new ?? "");
  }, [item.preview, item.action]);

  return (
    <div
      className={cn(
        "rounded-xl border bg-card/60 text-sm",
        awaiting ? "border-(--kit-border-strong) shadow-[0_0_0_3px_rgba(0,0,0,0.04)] dark:shadow-[0_0_0_3px_rgba(255,255,255,0.05)]" : "border-(--kit-border)"
      )}
    >
      <button
        className="flex w-full items-center gap-2 px-3 py-2 text-left"
        disabled={!hasDetails}
        onClick={() => setOpen(!expanded)}
        type="button"
      >
        {ICONS[item.action] ?? <Play className="h-4 w-4" />}
        <span className="font-medium">{VERBS[item.action] ?? item.action}</span>
        <span className="min-w-0 flex-1 truncate font-mono text-muted-foreground text-xs">{item.target}</span>
        {todo ? (
          <span className="shrink-0 text-[11px] text-muted-foreground tabular-nums" title="Items done in this list">
            {todo.done}/{todo.total} done
          </span>
        ) : (
          counts && <ChangePill added={counts.add} removed={counts.del} />
        )}
        {item.by === "streamhub" && (
          <span className="text-[11px] text-muted-foreground" title="StreamHub made this change itself, not Copilot">
            by StreamHub
          </span>
        )}
        {item.decidedBy && item.decidedBy !== "user" && (
          <span className="text-[11px] text-muted-foreground" title="This action was approved or rejected by another program, not in this window">
            via {item.decidedBy === "mcp" ? "MCP" : "API"}
          </span>
        )}
        <StatusBadge status={sent && item.status === "awaiting" ? "running" : item.status} />
        {hasDetails && (
          <ChevronRight className={cn("h-4 w-4 text-muted-foreground transition-transform", expanded && "rotate-90")} />
        )}
      </button>

      {expanded && (
        <div className="space-y-3 border-(--kit-border) border-t px-3 pt-3 pb-3">
          {item.warning && (
            <div className="kit-notice text-xs">
              <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
              {item.warning}
            </div>
          )}
          {item.error && <div className="kit-error-text">{shortError(item.error)}</div>}
          {item.reasons && item.reasons.length > 0 && (
            <div className="kit-notice flex-col space-y-1 p-2 text-xs">
              <div className="flex items-center gap-2">
                <span className="font-medium">Possible reasons</span>
                {item.code && <span className="kit-badge rounded-(--kit-radius-sm) font-mono font-normal">{item.code}</span>}
              </div>
              <ul className="list-disc space-y-0.5 pl-4 text-muted-foreground">
                {item.reasons.map((r) => (
                  <li key={r}>{r}</li>
                ))}
              </ul>
              {item.next && (
                <div className="text-muted-foreground">
                  <span className="font-medium text-foreground">What happens next: </span>
                  {item.next}
                </div>
              )}
            </div>
          )}
          {item.preview && item.action === "run" ? (
            // A script a chain or Automation > Scripts runs: its text, not a change.
            <div className="kit-panel overflow-hidden p-0">
              <div className="border-(--kit-border) border-b px-3 py-1.5 font-mono text-muted-foreground text-xs">{item.preview.path || "script"}</div>
              <div className="max-h-[28rem] overflow-auto">
                <CodeView language={languageForPath(item.preview.path)} text={item.preview.new ?? ""} />
              </div>
            </div>
          ) : (
            item.preview && (todo ? <TodoView preview={item.preview} todo={todo} /> : <DiffView preview={item.preview} />)
          )}
          {item.action === "run" &&
            (myLive ? (
              <LiveConsole live={myLive} />
            ) : item.window && running ? (
              <ConsoleView
                footer={`running in its own console window${myWindow ? ` for ${formatElapsed(myWindow.elapsed)}` : ""}`}
                lines={["Answer its questions in that window. Its output stays there; StreamHub notes the exit code here."]}
                title={`> ${item.target}`}
              />
            ) : ran && !awaiting ? (
              <ConsoleView footer={ran.status || undefined} lines={ran.lines} title={`> ${item.target}`} />
            ) : (
              <ConsoleView lines={[]} live={running} title={`> ${item.target}`} />
            ))}
          {ran?.notes && !awaiting && <div className="whitespace-pre-wrap text-muted-foreground text-xs">{ran.notes}</div>}
          {/* A to-do list that was written shows as its checklist; the result text would only repeat its lines. */}
          {item.output && !awaiting && item.action !== "run" && !(todo && item.status === "ok") && (
            <ActionOutput fallbackPath={item.target} output={item.output} />
          )}
          {item.action === "run" && !awaiting && (!running || myLive?.state === "question" || myLive?.state === "stuck") && item.target.trim() && (
            <OpenInWindow command={item.target} strong={needsTerminal || myLive?.state === "question"} />
          )}

          {awaiting && item.action === "web" && (item.allowOptions?.length ?? 0) > 0 && (
            <label className="flex flex-wrap items-center gap-2 text-xs">
              <span className="text-muted-foreground">Approve for</span>
              <select aria-label="What to allow with this approval" className="kit-select h-8 min-h-8 text-xs" onChange={(e) => setAllow(e.target.value)} value={allow}>
                <option value="">only these pages</option>
                {item.allowOptions!.map((o) => (
                  <option key={o} value={o}>
                    everything under {o}, from now on
                  </option>
                ))}
              </select>
            </label>
          )}
          {awaiting && blocks.length > 1 && (
            <fieldset className="kit-fieldset space-y-1 text-xs">
              <legend className="kit-legend">
                Changes in this step ({blocks.length - skip.length} of {blocks.length} kept): untick one to leave it out
              </legend>
              {blocks.map((b) => (
                <label className="flex min-w-0 items-center gap-2" key={b.index}>
                  <input
                    checked={!skip.includes(b.index)}
                    className="kit-check"
                    onChange={(e) => setSkip((s) => (e.target.checked ? s.filter((x) => x !== b.index) : [...s, b.index]))}
                    type="checkbox"
                  />
                  <span className="shrink-0 text-muted-foreground">
                    {b.oldCount ? `line ${b.oldStart}${b.oldCount > 1 ? `-${b.oldStart + b.oldCount - 1}` : ""}` : `after line ${b.oldStart - 1}`}
                    {` (+${b.newCount} -${b.oldCount})`}
                  </span>
                  <span className="min-w-0 truncate font-mono" title={b.first}>
                    {b.first}
                  </span>
                </label>
              ))}
              {skip.length === blocks.length && <div className="text-muted-foreground">Nothing is kept: reject the step instead, with a note for Copilot.</div>}
            </fieldset>
          )}
          {awaiting && (
            <div className="flex flex-wrap items-center gap-2">
              {item.action === "run" ? (
                <HoldButton
                  className="h-10 min-w-44"
                  holdDuration={1200}
                  holdingLabel="Keep holding..."
                  icon={<TerminalSquare className="h-4 w-4" />}
                  label="Hold to run"
                  onHoldComplete={() => decide("approve")}
                  variant="grey"
                />
              ) : (
                <GradientButton
                  className="h-10"
                  label={approveLabel(item)}
                  onClick={() => decide("approve")}
                  variant="neutral"
                />
              )}
              {/* The note goes with Reject only, so it reads as the other choice. */}
              <span className="text-muted-foreground text-xs">or</span>
              <Input aria-label="Note for Copilot, sent when rejecting"
                className="h-10 min-w-48 flex-1 text-xs"
                onChange={(e) => setNote(e.target.value)}
                placeholder="Optional note for Copilot (sent when rejecting)"
                value={note}
              />
              <button
                className="flex h-10 items-center gap-1 rounded-lg px-3 text-muted-foreground text-xs hover:bg-(--kit-surface-2) hover:text-foreground"
                onClick={() => decide("reject")}
                type="button"
              >
                <X className="h-3.5 w-3.5" /> Reject
              </button>
            </div>
          )}
          {(item.status === "ok" || item.status === "already applied") && item.summary && item.summary !== item.output && (
            <div className="flex items-center gap-1 text-muted-foreground text-xs">
              <Check className="h-3.5 w-3.5" /> {item.summary}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

/** The blocks of a change from the preview (one object or a list, as PowerShell sends them). */
function asBlocks(h: Preview["hunks"]): ChangeBlock[] {
  if (!h) return [];
  return (Array.isArray(h) ? h : [h]).filter((b) => b && typeof b.index === "number");
}

/** The approve button's words, by the kind of step (a web read is not a file). */
function approveLabel(item: ActionItem): string {
  switch (item.action) {
    case "web":
      return "Read";
    case "sql":
      return "Run query";
    case "remember":
      return "Save note";
    case "runbook":
      return "Run runbook";
    case "write":
    case "edit":
      return item.preview?.exists ? "Apply change" : "Create file";
    default:
      return "Approve";
  }
}

/** The card's red line: the reason only. Code and current lines stay in the output below it. */
function shortError(text: string): string {
  const first = text.split(/\n|\s(?:Current lines|The closest place|What differs:)/)[0].trim();
  return first.length > 320 ? `${first.slice(0, 317)}...` : first;
}
