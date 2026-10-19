import type { AgentEvent, ChangeSetView } from "@/lib/api";

/** The events from the last one of `type` on (`after`: from the one after it); all when there is none. */
function fromLast(events: AgentEvent[], type: string, after = false): AgentEvent[] {
  let idx = -1;
  events.forEach((e, i) => {
    if (e.type === type) idx = i;
  });
  return idx >= 0 ? events.slice(after ? idx + 1 : idx) : events;
}

/** Only the transcript since the last project switch. */
export const projectView = (events: AgentEvent[]) => fromLast(events, "project");

/** After "Clear chat history" (Settings > Privacy) nothing earlier is shown or recalled. */
export const keptView = (events: AgentEvent[]) => fromLast(events, "history-cleared", true);

/** The chat view starts at the last explicit "New chat"; the History tab keeps the whole project session. */
export const chatView = (events: AgentEvent[]) => fromLast(events, "newchat");

/** The user's own messages, oldest first, consecutive repeats once (Arrow Up history). */
export function promptHistory(events: AgentEvent[]): string[] {
  const out: string[] = [];
  for (const e of events) {
    const t = e.type === "user" ? (e.text ?? "").trim() : "";
    if (t && out[out.length - 1] !== t) out.push(t);
  }
  return out;
}

/** The change sets that can still be undone: an undo takes the newest one off the list. */
export function changeSets(events: AgentEvent[]): ChangeSetView[] {
  const list: ChangeSetView[] = [];
  for (const e of events) {
    if (e.type === "checkpoint") {
      const counts = Array.isArray(e.counts) ? e.counts : e.counts ? [e.counts] : [];
      list.push({ seq: e.seq, time: e.time, files: Array.isArray(e.files) ? e.files : e.files ? [e.files as unknown as string] : [], title: e.title || undefined, counts, changeSet: e.changeSet || undefined });
    }
    else if (e.type === "undo" && (e.files ?? []).length) list.pop();
  }
  return list;
}

const changedFiles = (e: AgentEvent) => e.type === "action-result" && Boolean(e.changed);
const TREE_EVENTS = new Set(["project", "undo", "fetch", "runbook", "chain", "review", "checkpoint"]);

/** New and changed files show in the tree right away: after each action that changed files, and at
 *  the end of every step (its change set). */
export const touchesFiles = (events: AgentEvent[]) => events.some((e) => TREE_EVENTS.has(e.type) || changedFiles(e));

/** The code review panel looks again after a review, a project switch or a change. */
export const touchesReview = (events: AgentEvent[]) => events.some((e) => e.type === "review" || e.type === "project" || changedFiles(e));

/** A new chat has started (or failed): the New chat button is free again. */
export const endsNewChat = (events: AgentEvent[]) => events.some((e) => e.type === "newchat" || e.type === "error");

/** A project path in one form: no trailing backslashes, lower case. */
export const projectKey = (path: string | null | undefined) => (path ?? "").replace(/\\+$/, "").toLowerCase();

/** Items of the open project, plus those without a project (such as a new chat), which belong to every project. */
export const inProject = <T extends { projectRoot?: string | null }>(items: T[] | undefined, key: string) =>
  (items ?? []).filter((x) => !x.projectRoot || projectKey(x.projectRoot) === key);
