import type { AgentEvent, QueueEntry } from "@/lib/api";

// Desktop notifications from this browser tab while it is in the background: approvals, questions,
// a plan to approve, finished or failed tasks, and the daily-limit pause. Nothing to install.
const KEY = "ccb.notify";

export function notifySupported(): boolean {
  return typeof window !== "undefined" && "Notification" in window;
}

export function notifyEnabled(): boolean {
  try {
    return notifySupported() && localStorage.getItem(KEY) === "1" && Notification.permission === "granted";
  } catch {
    return false;
  }
}

/** Turns notifications on (asking the browser's permission) or off. Returns whether they are on. */
export async function setNotifyEnabled(on: boolean): Promise<boolean> {
  if (on) {
    if (!notifySupported()) return false;
    const permission = Notification.permission === "granted" ? "granted" : await Notification.requestPermission();
    if (permission !== "granted") return false;
  }
  try {
    localStorage.setItem(KEY, on ? "1" : "0");
  } catch {
    /* storage blocked: notifications stay off */
  }
  return on;
}

export function notify(title: string, body = ""): void {
  if (!notifyEnabled() || !document.hidden) return;
  try {
    const n = new Notification(title, { body, tag: `${title}|${body}`.slice(0, 120) });
    n.onclick = () => {
      window.focus();
      n.close();
    };
  } catch {
    /* some browsers only allow notifications from a service worker */
  }
}

/** Notifications for new events: approvals, a person needed, questions, a plan to approve. */
export function notifyEvents(events: AgentEvent[]): void {
  for (const e of events) {
    if (e.type === "action" && e.status === "awaiting") notify("StreamHub: approval needed", `${e.action ?? ""} ${e.target ?? ""}`.trim());
    else if (e.type === "human-required") notify("StreamHub: your action is needed", e.text ?? "");
    else if (e.type === "clarify") notify("StreamHub: Copilot has questions", "Answer them so Copilot can plan the task.");
    else if (e.type === "plan-ready") notify("StreamHub: plan ready", "Approve the plan to start building, or change it.");
  }
}

/** Notifications for queue changes: tasks that finished or failed, and the daily-limit pause. */
export function notifyQueue(prev: Map<string, string>, queue: QueueEntry[], prevPause: string | null | undefined, pause: string | null | undefined): Map<string, string> {
  const next = new Map<string, string>();
  for (const q of queue) {
    next.set(q.id, q.status);
    const was = prev.get(q.id);
    if (!was || was === q.status) continue;
    if (q.status === "done") notify("StreamHub: done", q.title);
    else if (q.status === "failed") notify("StreamHub: failed", `${q.title}${q.error ? ` - ${q.error}` : ""}`);
  }
  if (!prevPause && pause) notify("StreamHub: queue paused", `Copilot's daily limit; it continues at ${new Date(pause).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}.`);
  else if (prevPause && !pause) notify("StreamHub: queue continues", "Copilot's daily limit has reset.");
  return next;
}
