import {
  AlertTriangle,
  Check,
  ChevronRight,
  FilePen,
  FilePlus2,
  FileSearch,
  FlaskConical,
  FolderInput,
  FolderSearch,
  ListTodo,
  Play,
  Workflow,
  Camera,
  RotateCcw,
  TerminalSquare,
  Trash2,
  X,
} from "lucide-react";
import { useMemo, useState } from "react";
import { cardExpanded, useCardView } from "@/lib/card-view";
import GradientButton from "@/components/kokonutui/gradient-button";
import HoldButton from "@/components/kokonutui/hold-button";
import { Input } from "@/components/ui/input";
import { api, type ChangeBlock, type Preview } from "@/lib/api";
import {
  approveLabel,
  asBlocks,
  blockPlace,
  canOpenInWindow,
  decidedVia,
  doneSummary,
  hasDetails,
  needsTerminal,
  offersAllow,
  ownsLive,
  runTitle,
  shortError,
  showsOutput,
  shownStatus,
  statusClass,
  statusLabel,
  verbFor,
} from "@/lib/action-card-view";
import { cn } from "@/lib/utils";
import { countChanges, diffLines } from "@/lib/diff";
import { ChangePill } from "./change-pill";
import { ActionOutput } from "./action-output";
import { DiffView } from "./diff-view";
import { TodoView } from "./todo-view";
import { isTodoChange, todoChange } from "@/lib/todo-list";
import { CodeView } from "./code-block";
import { languageForPath } from "@/lib/highlight";
import { formatElapsed, liveLines, parseRunOutput, useRunLive, waitText, type RunLive, type RunWindowState } from "@/lib/run-live";
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
  delete: <Trash2 className="h-4 w-4 text-muted-foreground" />,
  refs: <FileSearch className="h-4 w-4 text-muted-foreground" />,
  changes: <FilePen className="h-4 w-4 text-muted-foreground" />,
  test: <FlaskConical className="h-4 w-4 text-muted-foreground" />,
};

function StatusBadge({ status }: { status: string }) {
  return <span className={cn("text-xs", statusClass(status))}>{statusLabel(status)}</span>;
}

type TodoState = ReturnType<typeof todoChange>;

/** The header's marks after the target: a list's progress or the change count, and who made or decided it. */
function HeaderMarks({ item, todo, counts }: { item: ActionItem; todo: TodoState | null; counts: ReturnType<typeof countChanges> | null }) {
  const via = decidedVia(item.decidedBy);
  return (
    <>
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
      {via && (
        <span className="text-[11px] text-muted-foreground" title="This action was approved or rejected by another program, not in this window">
          via {via}
        </span>
      )}
    </>
  );
}

/** The header line: icon, verb, target, change count, who made or decided it, status. */
function CardHeader({
  item,
  todo,
  counts,
  sent,
  details,
  expanded,
  onToggle,
  took,
}: {
  item: ActionItem;
  todo: TodoState | null;
  counts: ReturnType<typeof countChanges> | null;
  sent: boolean;
  details: boolean;
  expanded: boolean;
  onToggle: () => void;
  took?: string;
}) {
  // A run card is titled by its program (and script): the whole command is in its console below.
  const title = item.action === "run" ? runTitle(item.target) || item.target : item.target;
  return (
    <button className="flex w-full items-center gap-2 px-3 py-2 text-left" disabled={!details} onClick={onToggle} type="button">
      {ICONS[item.action] ?? <Play className="h-4 w-4" />}
      <span className="font-medium">{verbFor(item.action)}</span>
      {/* One line while closed (the whole text on hover); open, the card shows all of it. */}
      <span
        className={cn("min-w-0 flex-1 font-mono text-muted-foreground text-xs", expanded ? "whitespace-pre-wrap break-words" : "truncate")}
        title={expanded ? undefined : item.target}
      >
        {title}
      </span>
      <HeaderMarks counts={counts} item={item} todo={todo} />
      <StatusBadge status={shownStatus(item.status, sent)} />
      {took && (
        <span className="shrink-0 text-[11px] text-muted-foreground tabular-nums" title="How long this step took">
          {took}
        </span>
      )}
      {details && <ChevronRight className={cn("h-4 w-4 text-muted-foreground transition-transform", expanded && "rotate-90")} />}
    </button>
  );
}

/** A failed step: possible reasons, its code and what happens next. */
function FailureReasons({ item }: { item: ActionItem }) {
  if (!item.reasons || item.reasons.length === 0) return null;
  return (
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
  );
}

/** The preview: a run's script text, a to-do checklist, or the change as lines. */
function PreviewBody({ item, todo }: { item: ActionItem; todo: TodoState | null }) {
  const preview = item.preview;
  if (!preview) return null;
  if (item.action === "run") {
    // The script a run starts (Copilot's command, a chain, Automation > Scripts): its whole text, not a change.
    return (
      <div className="kit-panel overflow-hidden p-0">
        <div className="border-(--kit-border) border-b px-3 py-1.5 font-mono text-muted-foreground text-xs">{preview.path || "script"}</div>
        <div className="max-h-[28rem] overflow-auto">
          <CodeView language={languageForPath(preview.path)} text={preview.new ?? ""} />
        </div>
      </div>
    );
  }
  return todo ? <TodoView preview={preview} todo={todo} /> : <DiffView preview={preview} />;
}

/** A run's console: live output, a run in its own window, the finished output, or an empty console. */
function RunConsole({
  item,
  myLive,
  myWindow,
  ran,
  running,
  awaiting,
}: {
  item: ActionItem;
  myLive: RunLive | null;
  myWindow?: RunWindowState;
  ran: ReturnType<typeof parseRunOutput> | null;
  running: boolean;
  awaiting: boolean;
}) {
  if (myLive) return <LiveConsole live={myLive} />;
  if (item.window && running) {
    return (
      <ConsoleView
        footer={`running in its own console window${myWindow ? ` for ${formatElapsed(myWindow.elapsed)}` : ""}`}
        lines={["Answer its questions in that window. Its output stays there; StreamHub notes the exit code here."]}
        title={`> ${item.target}`}
      />
    );
  }
  if (ran && !awaiting) return <ConsoleView footer={ran.status || undefined} lines={ran.lines} title={`> ${item.target}`} />;
  return <ConsoleView lines={[]} live={running} title={`> ${item.target}`} />;
}

/** web: what to allow from now on with this approval ("" = only these pages). */
function AllowSelect({ options, allow, setAllow }: { options: string[]; allow: string; setAllow: (v: string) => void }) {
  return (
    <label className="flex flex-wrap items-center gap-2 text-xs">
      <span className="text-muted-foreground">Approve for</span>
      <select aria-label="What to allow with this approval" className="kit-select h-8 min-h-8 text-xs" onChange={(e) => setAllow(e.target.value)} value={allow}>
        <option value="">only these pages</option>
        {options.map((o) => (
          <option key={o} value={o}>
            everything under {o}, from now on
          </option>
        ))}
      </select>
    </label>
  );
}

/** A tick box per block of a change: an unticked block is left out when approving. */
function BlockPicker({ blocks, skip, setSkip }: { blocks: ChangeBlock[]; skip: number[]; setSkip: React.Dispatch<React.SetStateAction<number[]>> }) {
  return (
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
          <span className="shrink-0 text-muted-foreground">{blockPlace(b)}</span>
          <span className="min-w-0 truncate font-mono" title={b.first}>
            {b.first}
          </span>
        </label>
      ))}
      {skip.length === blocks.length && <div className="text-muted-foreground">Nothing is kept: reject the step instead, with a note for Copilot.</div>}
    </fieldset>
  );
}

/** Approve (hold to run for a command) or reject with an optional note. */
function DecisionBar({
  item,
  note,
  setNote,
  decide,
}: {
  item: ActionItem;
  note: string;
  setNote: (v: string) => void;
  decide: (decision: "approve" | "reject") => void;
}) {
  return (
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
        <GradientButton className="h-10" label={approveLabel(item)} onClick={() => decide("approve")} variant="neutral" />
      )}
      {/* The note goes with Reject only, so it reads as the other choice. */}
      <span className="text-muted-foreground text-xs">or</span>
      <Input
        aria-label="Note for Copilot, sent when rejecting"
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
  );
}

/** The change counts and the to-do checklist of a step's preview (not for a run's script). */
function usePreviewSummary(item: ActionItem) {
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
  return { counts, todo };
}

/** The command running now, when it is this card's: its live output and its own console window. */
function useMyRun(item: ActionItem) {
  const { live, windows } = useRunLive();
  const running = item.status === "running";
  const myLive = live && ownsLive(item, live.id) ? live : null;
  const myWindow = item.window && running ? windows.find((w) => w.id === item.id) : undefined;
  return { running, myLive, myWindow };
}

/** The warning, the error and the reasons a step failed. */
function CardNotices({ item }: { item: ActionItem }) {
  return (
    <>
      {item.warning && (
        <div className="kit-notice text-xs">
          <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          {item.warning}
        </div>
      )}
      {item.error && <div className="kit-error-text">{shortError(item.error)}</div>}
      <FailureReasons item={item} />
    </>
  );
}

/** What a step did: a run's console and notes, the result text, and Open in a window. */
function CardResult({
  item,
  todo,
  awaiting,
  running,
  myLive,
  myWindow,
}: {
  item: ActionItem;
  todo: ReturnType<typeof todoChange> | null;
  awaiting: boolean;
  running: boolean;
  myLive: RunLive | null;
  myWindow?: RunWindowState;
}) {
  const ran = item.action === "run" && item.output ? parseRunOutput(item.output) : null;
  return (
    <>
      {item.action === "run" && <RunConsole awaiting={awaiting} item={item} myLive={myLive} myWindow={myWindow} ran={ran} running={running} />}
      {ran?.notes && !awaiting && <div className="whitespace-pre-wrap text-muted-foreground text-xs">{ran.notes}</div>}
      {/* A to-do list that was written shows as its checklist; the result text would only repeat its lines. */}
      {showsOutput(item, awaiting, Boolean(todo)) && <ActionOutput fallbackPath={item.target} output={item.output ?? ""} />}
      {canOpenInWindow(item, awaiting, running, myLive?.state) && (
        <OpenInWindow command={item.target} strong={needsTerminal(item) || myLive?.state === "question"} />
      )}
    </>
  );
}

/** The approval: what to allow on the web, which blocks of a change, and the decision itself. */
function ApprovalParts({ item, choice, decide }: { item: ActionItem; choice: ReturnType<typeof useApprovalChoice>; decide: (decision: "approve" | "reject") => void }) {
  const blocks = asBlocks(item.preview?.hunks);
  return (
    <>
      {offersAllow(item, true) && <AllowSelect allow={choice.allow} options={item.allowOptions ?? []} setAllow={choice.setAllow} />}
      {blocks.length > 1 && <BlockPicker blocks={blocks} setSkip={choice.setSkip} skip={choice.skip} />}
      <DecisionBar decide={decide} item={item} note={choice.note} setNote={choice.setNote} />
    </>
  );
}

/** What the person chose with an approval; kept on the card, so a send that fails keeps it. */
function useApprovalChoice() {
  const [note, setNote] = useState("");
  // Blocks of a change the person unticked: left out when approving (the rest is written).
  const [skip, setSkip] = useState<number[]>([]);
  // web: a part of the site to allow from now on with this approval ("" = only these pages).
  const [allow, setAllow] = useState("");
  return { note, setNote, skip, setSkip, allow, setAllow };
}

/** `took`: how long the step took, once it finished (shown in the header). */
export function ActionCard({ item, took }: { item: ActionItem; took?: string }) {
  // null: follow the setting (Settings > This browser > Cards) until the person opens or closes it.
  const [open, setOpen] = useState<boolean | null>(null);
  const view = useCardView();
  const [sent, setSent] = useState(false);
  const choice = useApprovalChoice();
  const awaiting = item.status === "awaiting" && !sent;
  // The command running now: its output as it comes (the card opens to show it).
  const { running, myLive, myWindow } = useMyRun(item);
  // Open by default; with auto-collapse a finished step folds up (the reader can still open or close any card).
  const expanded = cardExpanded(awaiting, open, Boolean(myLive), shownStatus(item.status, sent), view);
  const { counts, todo } = usePreviewSummary(item);
  const summary = doneSummary(item);

  const decide = async (decision: "approve" | "reject") => {
    const { note, skip, allow } = choice;
    setSent(true);
    try {
      await api.approve(item.id, decision, note, decision === "approve" ? skip : [], decision === "approve" ? allow : "");
    } catch {
      setSent(false);
    }
  };

  return (
    <div
      className={cn(
        "rounded-xl border bg-card/60 text-sm",
        awaiting ? "border-(--kit-border-strong) shadow-[0_0_0_3px_rgba(0,0,0,0.04)] dark:shadow-[0_0_0_3px_rgba(255,255,255,0.05)]" : "border-(--kit-border)"
      )}
    >
      <CardHeader counts={counts} details={hasDetails(item)} expanded={expanded} item={item} onToggle={() => setOpen(!expanded)} sent={sent} todo={todo} took={took} />

      {expanded && (
        <div className="space-y-3 border-(--kit-border) border-t px-3 pt-3 pb-3">
          <CardNotices item={item} />
          <PreviewBody item={item} todo={todo} />
          <CardResult awaiting={awaiting} item={item} myLive={myLive} myWindow={myWindow} running={running} todo={todo} />
          {awaiting && <ApprovalParts choice={choice} decide={decide} item={item} />}
          {summary && (
            <div className="flex items-center gap-1 text-muted-foreground text-xs">
              <Check className="h-3.5 w-3.5" /> {summary}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
