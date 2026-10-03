import {
  AlertTriangle,
  Check,
  ChevronRight,
  FilePen,
  FilePlus2,
  FileSearch,
  FolderSearch,
  ListTodo,
  Play,
  TerminalSquare,
  X,
} from "lucide-react";
import { useMemo, useState } from "react";
import GradientButton from "@/components/kokonutui/gradient-button";
import HoldButton from "@/components/kokonutui/hold-button";
import { Input } from "@/components/ui/input";
import { api, type Preview } from "@/lib/api";
import { cn } from "@/lib/utils";
import { countChanges, diffLines } from "@/lib/diff";
import { ChangePill } from "./change-pill";
import { ActionOutput } from "./action-output";
import { DiffView } from "./diff-view";

export interface ActionItem {
  id: string;
  action: string;
  target: string;
  status: string; // running | awaiting | ok | already applied | failed | rejected | skipped
  preview?: Preview | null;
  warning?: string | null;
  error?: string;
  summary?: string;
  output?: string;
  /** Who approved or rejected it: "user" (you, in the web app), "api" or "mcp". */
  decidedBy?: string;
  /** Failed step: category, possible reasons and what happens next. */
  code?: string;
  reasons?: string[];
  next?: string;
}

const ICONS: Record<string, React.ReactNode> = {
  read: <FileSearch className="h-4 w-4 text-muted-foreground" />,
  glob: <FolderSearch className="h-4 w-4 text-muted-foreground" />,
  grep: <FolderSearch className="h-4 w-4 text-muted-foreground" />,
  write: <FilePlus2 className="h-4 w-4 text-muted-foreground" />,
  edit: <FilePen className="h-4 w-4 text-muted-foreground" />,
  run: <TerminalSquare className="h-4 w-4 text-muted-foreground" />,
  todo: <ListTodo className="h-4 w-4 text-muted-foreground" />,
};

const VERBS: Record<string, string> = {
  read: "Read",
  glob: "List",
  grep: "Search",
  write: "Write",
  edit: "Edit",
  run: "Run",
  todo: "Plan",
};

function StatusBadge({ status }: { status: string }) {
  const map: Record<string, string> = {
    running: "text-muted-foreground",
    awaiting: "font-medium text-foreground",
    ok: "text-muted-foreground",
    "already applied": "text-muted-foreground",
    failed: "text-rose-500",
    rejected: "text-zinc-500",
    skipped: "text-zinc-500",
  };
  const label: Record<string, string> = {
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
  const [open, setOpen] = useState(item.status === "awaiting");
  const [note, setNote] = useState("");
  const [sent, setSent] = useState(false);
  const awaiting = item.status === "awaiting" && !sent;
  const expanded = open || awaiting;

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
    if (!item.preview) return null;
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
        onClick={() => setOpen((o) => !o)}
        type="button"
      >
        {ICONS[item.action] ?? <Play className="h-4 w-4" />}
        <span className="font-medium">{VERBS[item.action] ?? item.action}</span>
        <span className="min-w-0 flex-1 truncate font-mono text-muted-foreground text-xs">{item.target}</span>
        {counts && <ChangePill added={counts.add} removed={counts.del} />}
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
          {item.error && <div className="text-rose-500 text-xs">{item.error}</div>}
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
          {item.preview && <DiffView preview={item.preview} />}
          {item.action === "run" && (
            <pre className="overflow-auto rounded-lg bg-black/80 px-3 py-2 font-mono text-xs text-zinc-100">
              <span className="select-none text-zinc-400">&gt; </span>
              {item.target}
            </pre>
          )}
          {item.output && !awaiting && (
            <ActionOutput fallbackPath={item.target} output={item.output} />
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
              <Input
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
