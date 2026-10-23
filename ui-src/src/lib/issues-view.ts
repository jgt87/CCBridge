import type { IssueCategory, IssueItem } from "./api";

// The rules of the Issues panel (components/ccb/issues-panel.tsx): the kinds of problems, what the
// filters show, the per-file groups, the counts on the filter buttons and the texts.

export const ISSUE_CATEGORIES: { id: IssueCategory; label: string; help: string }[] = [
  { id: "error", label: "Errors", help: "Broken syntax, unclosed blocks or strings, missing local files, unknown commands" },
  { id: "secret", label: "Secrets", help: "Keys, tokens and passwords written in the code" },
  { id: "health", label: "Code health", help: "Functions that are very complex, very deeply nested or very long" },
];

const STATUS_TEXT: Record<IssueItem["status"], string> = { open: "open", fixing: "fixing", "gave up": "gave up", ignored: "ignored" };

export type IssueCounts = Record<IssueCategory, number> & { fixing: number; gaveUp: number; ignored: number };

/** The set with v added, or removed when it was there. */
export function toggled<T>(set: Set<T>, v: T): Set<T> {
  const n = new Set(set);
  if (n.has(v)) n.delete(v);
  else n.add(v);
  return n;
}

/** The problems of the kinds shown; ignored ones only when asked for. */
export function visibleIssues(items: IssueItem[], show: Set<IssueCategory>, showIgnored: boolean): IssueItem[] {
  return items.filter((i) => show.has(i.category) && (showIgnored || i.status !== "ignored"));
}

/** The problems per file, files in the order they first appear. */
export function issuesByFile(items: IssueItem[]): [string, IssueItem[]][] {
  const m = new Map<string, IssueItem[]>();
  for (const i of items) m.set(i.path, [...(m.get(i.path) ?? []), i]);
  return [...m.entries()];
}

/** Open problems per kind, plus those being fixed, given up on and ignored (each counted once). */
export function issueCounts(items: IssueItem[]): IssueCounts {
  const c = { error: 0, secret: 0, health: 0, fixing: 0, gaveUp: 0, ignored: 0 };
  for (const i of items) {
    if (i.status === "ignored") c.ignored++;
    else if (i.status === "fixing") c.fixing++;
    else if (i.status === "gave up") c.gaveUp++;
    else c[i.category]++;
  }
  return c;
}

/** The line about fixes under the filters; "" when nothing is being fixed or given up on. */
export function fixProgressText(c: IssueCounts): string {
  return (c.fixing > 0 ? `${c.fixing} being fixed. ` : "") + (c.gaveUp > 0 ? `${c.gaveUp} still there after the fix attempts (gave up).` : "");
}

/** A file's list is open when clicked open, or with Expand all when not clicked closed. */
export function fileOpen(path: string, allOpen: boolean, clicked: Set<string>): boolean {
  return allOpen ? !clicked.has(path) : clicked.has(path);
}

/** The answer to a fix request. */
export function fixNoticeText(r: { queued: number; issues: number }): string {
  return r.queued ? `Queued ${r.queued} fix task(s) for ${r.issues} problem(s); each file is scanned again afterwards.` : "Nothing to fix for the chosen kinds.";
}

/** The line under a problem: its kind, status, fix attempts and note. */
export function issueMetaText(i: IssueItem): string {
  const kind = ISSUE_CATEGORIES.find((c) => c.id === i.category)?.label;
  return `${kind} · ${STATUS_TEXT[i.status]}` + (i.attempts > 0 ? ` · ${i.attempts} attempt(s)` : "") + (i.note ? ` · ${i.note}` : "");
}
