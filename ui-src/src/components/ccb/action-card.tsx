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
import { api, type Preview } from "@/lib/api";
import { cn } from "@/lib/utils";
import { countChanges, diffLines } from "@/lib/diff";
import { ChangePill } from "./change-pill";
import { ActionOutput } from "./action-output";
import { DiffView } from "./diff-view";
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
          "flex h-8 items-center gap-1.5 rounded-lg px-2.5 hover:bg-black/5 dark:hover:bg-white/5",
          strong ? "border border-black/20 text-foreground dark:border-white/20" : "text-muted-foreground hover:text-foreground"
        )}
        disabled={state === "busy"}
        onClick={open}
        title="Runs this command in its own console window in the project folder. You can watch it and answer its questions there; StreamHub notes the exit code."
        type="button"
      >
        <TerminalSquare className="h-3.5 w-3.5" /> Open in a window
      </button>
      {state === "opened" && <span className="text-muted-foreground">Opened: see the console window. Its result shows on a new card.</span>}
      {state && state !== "busy" && state !== "opened" && <span className="text-rose-500 dark:text-rose-400">{state}</span>}
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
    failed: "text-rose-500 dark:text-rose-400",
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
      await api.approve(item.id, decision, note);
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

  return (
    <div
      className={cn(
        "rounded-xl border bg-card/60 text-sm",
        awaiting ? "border-black/30 shadow-[0_0_0_3px_rgba(0,0,0,0.04)] dark:border-white/30 dark:shadow-[0_0_0_3px_rgba(255,255,255,0.05)]" : "border-black/10 dark:border-white/10"
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
        {counts && <ChangePill added={counts.add} removed={counts.del} />}
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
        <div className="space-y-3 border-black/5 border-t px-3 pt-3 pb-3 dark:border-white/5">
          {item.warning && (
            <div className="flex items-start gap-2 rounded-lg bg-black/5 px-3 py-2 text-foreground text-xs dark:bg-white/10">
              <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
              {item.warning}
            </div>
          )}
          {item.error && <div className="text-rose-500 dark:text-rose-400 text-xs">{item.error}</div>}
          {item.reasons && item.reasons.length > 0 && (
            <div className="space-y-1 rounded-md bg-black/[0.03] p-2 text-xs dark:bg-white/[0.04]">
              <div className="flex items-center gap-2">
                <span className="font-medium">Possible reasons</span>
                {item.code && <span className="rounded bg-black/5 px-1.5 py-0.5 font-mono text-muted-foreground dark:bg-white/10">{item.code}</span>}
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
            <div className="overflow-hidden rounded-lg border border-black/10 dark:border-white/10">
              <div className="border-black/10 border-b px-3 py-1.5 font-mono text-muted-foreground text-xs dark:border-white/10">{item.preview.path || "script"}</div>
              <div className="max-h-[28rem] overflow-auto">
                <CodeView language={languageForPath(item.preview.path)} text={item.preview.new ?? ""} />
              </div>
            </div>
          ) : (
            item.preview && <DiffView preview={item.preview} />
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
          {item.output && !awaiting && item.action !== "run" && (
            <ActionOutput fallbackPath={item.target} output={item.output} />
          )}
          {item.action === "run" && !awaiting && (!running || myLive?.state === "question" || myLive?.state === "stuck") && item.target.trim() && (
            <OpenInWindow command={item.target} strong={needsTerminal || myLive?.state === "question"} />
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
                  label={item.preview?.exists ? "Apply change" : "Create file"}
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
                className="flex h-10 items-center gap-1 rounded-lg px-3 text-muted-foreground text-xs hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5"
                onClick={() => decide("reject")}
                type="button"
              >
                <X className="h-3.5 w-3.5" /> Reject
              </button>
            </div>
          )}
          {(item.status === "ok" || item.status === "already applied") && item.summary && (
            <div className="flex items-center gap-1 text-muted-foreground text-xs">
              <Check className="h-3.5 w-3.5" /> {item.summary}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
