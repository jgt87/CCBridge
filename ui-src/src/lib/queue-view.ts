import type { QueueEntry } from "@/lib/api";

const clock = (s: string | null) => (s ? new Date(s).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "");

/** A task that can still be cancelled: queued, running or waiting for approval. */
export function isActive(status: QueueEntry["status"]): boolean {
  return status === "queued" || status === "running" || status === "awaiting";
}

/** "10:42, 35 s" for a finished task, else the time it started (or was queued). */
export function queueWhen(e: Pick<QueueEntry, "created" | "started" | "finished">): string {
  if (e.finished && e.started) {
    const sec = Math.max(0, Math.round((new Date(e.finished).getTime() - new Date(e.started).getTime()) / 1000));
    return `${clock(e.started)}, ${sec < 90 ? `${sec} s` : `${Math.round(sec / 60)} min`}`;
  }
  return clock(e.started ?? e.created);
}

/** Who started a task, as the row says it: you, scheduled, or the program's name (MCP, API...). */
export function sourceLabel(source: string): string {
  if (source === "user") return "you";
  if (source === "schedule") return "scheduled";
  return source.toUpperCase();
}
