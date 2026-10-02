import { Bot, CircleCheck, CircleDashed, CircleX, Clock, FileText, Hand, LoaderCircle, User, X } from "lucide-react";
import type { QueueEntry } from "@/lib/api";
import { api } from "@/lib/api";
import { cn } from "@/lib/utils";

const STATUS: Record<QueueEntry["status"], { label: string; icon: React.ReactNode }> = {
  queued: { label: "queued", icon: <Clock className="h-3.5 w-3.5" /> },
  running: { label: "running", icon: <LoaderCircle className="h-3.5 w-3.5 animate-spin" /> },
  awaiting: { label: "needs approval", icon: <Hand className="h-3.5 w-3.5" /> },
  done: { label: "done", icon: <CircleCheck className="h-3.5 w-3.5" /> },
  failed: { label: "failed", icon: <CircleX className="h-3.5 w-3.5 text-rose-500" /> },
  cancelled: { label: "cancelled", icon: <CircleDashed className="h-3.5 w-3.5" /> },
};

function when(e: QueueEntry): string {
  const t = (s: string | null) => (s ? new Date(s).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "");
  if (e.finished && e.started) {
    const sec = Math.max(0, Math.round((new Date(e.finished).getTime() - new Date(e.started).getTime()) / 1000));
    return `${t(e.started)}, ${sec < 90 ? `${sec} s` : `${Math.round(sec / 60)} min`}`;
  }
  return t(e.started ?? e.created);
}

/** The queue: every task, whatever started it, with its status and result. */
export function QueuePanel({ queue, onOpen }: { queue: QueueEntry[]; onOpen: (path: string) => void }) {
  if (!queue.length) return <p className="text-muted-foreground text-sm">Tasks you send, fetches, runbooks and tasks from MCP clients appear here.</p>;
  return (
    <div className="space-y-1.5">
      {queue.map((e) => {
        const st = STATUS[e.status] ?? STATUS.queued;
        const active = e.status === "queued" || e.status === "running" || e.status === "awaiting";
        return (
          <div className={cn("rounded-lg border border-black/10 p-2 dark:border-white/10", e.status === "awaiting" && "border-black/30 dark:border-white/30")} key={e.id}>
            <div className="flex items-start gap-2">
              <span className="mt-0.5 text-muted-foreground" title={st.label}>
                {st.icon}
              </span>
              <span className="line-clamp-2 min-w-0 flex-1 text-sm" title={e.title}>
                {e.title}
              </span>
              {active && (
                <button
                  className="shrink-0 rounded p-0.5 text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5"
                  onClick={() => api.cancelQueued(e.id)}
                  title={e.status === "queued" ? "Remove from the queue" : "Stop this task"}
                  type="button"
                >
                  <X className="h-3.5 w-3.5" />
                </button>
              )}
            </div>
            <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 pl-5 text-muted-foreground text-xs">
              <span className="inline-flex items-center gap-1" title={`Started by ${e.source}`}>
                {e.source === "user" ? <User className="h-3 w-3" /> : <Bot className="h-3 w-3" />}
                {e.source === "user" ? "you" : e.source.toUpperCase()}
              </span>
              <span>{st.label}</span>
              {when(e) && <span>{when(e)}</span>}
              {e.messages > 0 && <span title="Copilot messages used">{e.messages} msg</span>}
              {e.project && <span className="truncate">{e.project}</span>}
            </div>
            {e.error ? (
              <div className="mt-1 line-clamp-3 pl-5 text-rose-600 text-xs dark:text-rose-400" title={e.error}>
                {e.error}
                {e.errId ? ` (${e.errId})` : ""}
              </div>
            ) : (
              e.summary && (
                <div className="mt-1 line-clamp-3 pl-5 text-muted-foreground text-xs" title={e.summary}>
                  {e.summary}
                </div>
              )
            )}
            {(e.resultPath || (e.changed && e.changed.length > 0)) && (
              <div className="mt-1 flex flex-wrap gap-1 pl-4">
                {e.resultPath && (
                  <button className="inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs hover:bg-black/5 dark:hover:bg-white/5" onClick={() => onOpen(e.resultPath!)} type="button">
                    <FileText className="h-3 w-3" /> {e.resultPath}
                  </button>
                )}
                {e.changed && e.changed.length > 0 && (
                  <span className="px-1.5 py-0.5 text-muted-foreground text-xs" title={e.changed.join("\n")}>
                    {e.changed.length} file(s) changed
                  </span>
                )}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}