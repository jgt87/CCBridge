import { Bot, CalendarClock, CircleCheck, CircleDashed, CircleX, Clock, FileText, Hand, LoaderCircle, PauseCircle, User, X } from "lucide-react";
import type { QueueEntry } from "@/lib/api";
import { api } from "@/lib/api";
import { isActive, queueWhen, sourceLabel } from "@/lib/queue-view";
import { cn } from "@/lib/utils";
import { KeepOpenNote, QUEUE_NOTE } from "./keep-open-note";

const STATUS: Record<QueueEntry["status"], { label: string; icon: React.ReactNode }> = {
  queued: { label: "queued", icon: <Clock className="h-3.5 w-3.5" /> },
  running: { label: "running", icon: <LoaderCircle className="h-3.5 w-3.5 animate-spin" /> },
  awaiting: { label: "needs approval", icon: <Hand className="h-3.5 w-3.5" /> },
  done: { label: "done", icon: <CircleCheck className="h-3.5 w-3.5" /> },
  failed: { label: "failed", icon: <CircleX className="h-3.5 w-3.5 text-(--kit-error)" /> },
  cancelled: { label: "cancelled", icon: <CircleDashed className="h-3.5 w-3.5" /> },
};

function SourceIcon({ source }: { source: string }) {
  if (source === "user") return <User className="h-3 w-3" />;
  if (source === "schedule") return <CalendarClock className="h-3 w-3" />;
  return <Bot className="h-3 w-3" />;
}

/** Copilot's daily limit is reached: the queue waits until the given time, or until Resume now. */
function PausedNotice({ until }: { until: string }) {
  return (
    <div className="kit-notice p-2 text-xs">
      <PauseCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
      <span className="flex-1">
        Paused until {new Date(until).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}: Copilot's daily limit is reached. Tasks wait and continue then.
      </span>
      <button className="kit-btn kit-btn--ghost kit-btn--sm shrink-0" onClick={() => api.resumeQueue()} title="Try again now" type="button">
        Resume now
      </button>
    </div>
  );
}

/** Who started it, the status, when, Copilot messages used and the project. */
function QueueMeta({ e, label }: { e: QueueEntry; label: string }) {
  const at = queueWhen(e);
  return (
    <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 pl-5 text-muted-foreground text-xs">
      <span className="inline-flex items-center gap-1" title={`Started by ${e.source}`}>
        <SourceIcon source={e.source} />
        {sourceLabel(e.source)}
      </span>
      <span>{label}</span>
      {at && <span>{at}</span>}
      {e.messages > 0 && <span title="Copilot messages used">{e.messages} msg</span>}
      {e.project && <span className="truncate">{e.project}</span>}
    </div>
  );
}

/** The error (with its id), else the summary. */
function QueueOutcome({ e }: { e: QueueEntry }) {
  if (e.error)
    return (
      <div className="kit-error-text mt-1 line-clamp-3 pl-5" title={e.error}>
        {e.error}
        {e.errId ? ` (${e.errId})` : ""}
      </div>
    );
  if (!e.summary) return null;
  return (
    <div className="mt-1 line-clamp-3 pl-5 text-muted-foreground text-xs" title={e.summary}>
      {e.summary}
    </div>
  );
}

/** The changed files: a button to the change set on the History tab when there is one, else a plain count. */
function ChangedFiles({ changed, changeSeq, onShowChange }: { changed: string[]; changeSeq?: number | null; onShowChange?: (seq: number) => void }) {
  if (changeSeq && onShowChange)
    return (
      <button
        className="kit-btn kit-btn--ghost kit-btn--sm text-muted-foreground hover:text-foreground"
        onClick={() => onShowChange(changeSeq)}
        title={`Show this change set on the History tab:\n${changed.join("\n")}`}
        type="button"
      >
        {changed.length} file(s) changed
      </button>
    );
  return (
    <span className="px-1.5 py-0.5 text-muted-foreground text-xs" title={changed.join("\n")}>
      {changed.length} file(s) changed
    </span>
  );
}

/** The result file and the changed files. */
function QueueLinks({ e, onOpen, onShowChange }: { e: QueueEntry; onOpen: (path: string) => void; onShowChange?: (seq: number) => void }) {
  const changed = e.changed && e.changed.length > 0 ? e.changed : null;
  if (!e.resultPath && !changed) return null;
  return (
    <div className="mt-1 flex flex-wrap gap-1 pl-4">
      {e.resultPath && (
        <button className="kit-btn kit-btn--ghost kit-btn--sm" onClick={() => onOpen(e.resultPath!)} type="button">
          <FileText className="h-3 w-3" /> {e.resultPath}
        </button>
      )}
      {changed && <ChangedFiles changeSeq={e.changeSeq} changed={changed} onShowChange={onShowChange} />}
    </div>
  );
}

/** One task in the queue. */
function QueueRow({ e, onOpen, onShowChange }: { e: QueueEntry; onOpen: (path: string) => void; onShowChange?: (seq: number) => void }) {
  const st = STATUS[e.status] ?? STATUS.queued;
  return (
    <div className={cn("kit-panel p-2", e.status === "awaiting" && "border-(--kit-border-strong)")}>
      <div className="flex items-start gap-2">
        <span className="mt-0.5 text-muted-foreground" title={st.label}>
          {st.icon}
        </span>
        <span className="line-clamp-2 min-w-0 flex-1 text-sm" title={e.title}>
          {e.title}
        </span>
        {isActive(e.status) && (
          <button
            className="kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm shrink-0 text-muted-foreground hover:text-foreground"
            onClick={() => api.cancelQueued(e.id)}
            title={e.status === "queued" ? "Remove from the queue" : "Stop this task"}
            type="button"
          >
            <X className="h-3.5 w-3.5" />
          </button>
        )}
      </div>
      <QueueMeta e={e} label={st.label} />
      {e.note && <div className="mt-1 pl-5 text-muted-foreground text-xs italic">{e.note}</div>}
      <QueueOutcome e={e} />
      <QueueLinks e={e} onOpen={onOpen} onShowChange={onShowChange} />
    </div>
  );
}

/** The queue: every task, whatever started it, with its status and result. */
export function QueuePanel({ queue, onOpen, pausedUntil, onShowChange }: { queue: QueueEntry[]; onOpen: (path: string) => void; pausedUntil?: string | null; onShowChange?: (seq: number) => void }) {
  const paused = pausedUntil ? <PausedNotice until={pausedUntil} /> : null;
  if (!queue.length)
    return (
      <div className="space-y-1.5">
        {paused}
        <p className="kit-empty py-3 text-sm">Tasks you send, runbooks, chains, scheduled tasks and tasks from MCP clients appear here.</p>
      </div>
    );
  return (
    <div className="space-y-1.5">
      {paused}
      {queue.some((e) => isActive(e.status)) && <KeepOpenNote>{QUEUE_NOTE}</KeepOpenNote>}
      {queue.map((e) => (
        <QueueRow e={e} key={e.id} onOpen={onOpen} onShowChange={onShowChange} />
      ))}
    </div>
  );
}
