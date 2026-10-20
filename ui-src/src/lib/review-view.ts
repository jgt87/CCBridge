import type { ReviewFinding, ReviewSummary } from "@/lib/api";

export const FOCUS = ["bugs", "security", "performance", "structure", "readability", "tests"];
export const DEFAULT_FOCUS = ["bugs", "security", "performance", "structure"];
export const SEVERITY: ReviewFinding["severity"][] = ["high", "medium", "low"];

/** What the review would take, as the review form's estimate says it. */
export interface ReviewEstimate {
  files: number;
  messages: number;
  scopeText: string;
}

/**
 * Loads that may overtake each other (a report opened, then another before the first arrived): only
 * the latest `ask` shows; an earlier one that arrives later resolves to null and is dropped.
 */
export function latestOnly<K, T>(): (key: K, load: () => Promise<T>) => Promise<T | null> {
  let wanted: K | undefined;
  return (key, load) => {
    wanted = key;
    return load().then((r) => (wanted === key ? r : null));
  };
}

/** The files or folders typed in the form: split on commas and new lines, blanks dropped. */
export function splitPaths(paths: string): string[] {
  return paths
    .split(/[,\n]/)
    .map((p) => p.trim())
    .filter(Boolean);
}

/** Adds a focus area that is not chosen, removes one that is. */
export function toggleFocus(cur: string[], f: string): string[] {
  return cur.includes(f) ? cur.filter((x) => x !== f) : [...cur, f];
}

/** Adds an id that is not ticked, removes one that is (a new set). */
export function togglePicked(cur: Set<string>, id: string): Set<string> {
  const next = new Set(cur);
  if (next.has(id)) next.delete(id);
  else next.add(id);
  return next;
}

/** The findings ticked when a report opens: verified or general, not queued, not ignored, not low. */
export function defaultPicked(findings: ReviewFinding[]): Set<string> {
  return new Set(findings.filter((f) => f.status !== "unverified" && !f.fixQueueId && !f.ignored && f.severity !== "low").map((f) => f.id));
}

/** The line under the review form: an error, the estimate, or what is never reviewed. */
export function estimateText(error: string, estimate: ReviewEstimate | null): string {
  if (error) return error;
  if (!estimate) return "Build output, lock files, data and Source/ are never reviewed.";
  return estimate.files
    ? `${estimate.files} file(s), about ${estimate.messages} Copilot message(s). Read-only: nothing is changed.`
    : `No code files in ${estimate.scopeText}.`;
}

/** The counts line of a saved review. */
export function reviewCounts(r: ReviewSummary): string {
  return `${r.scopeText} · ${r.high} high · ${r.medium} medium · ${r.low} low${r.unverified ? ` · ${r.unverified} unverified` : ""}${r.ignored ? ` · ${r.ignored} ignored` : ""}`;
}

/** A report's findings in the order shown: high, medium, low (verified or general), then unverified; empty groups left out. */
export function findingGroups(findings: ReviewFinding[]): { key: string; list: ReviewFinding[] }[] {
  const groups = SEVERITY.map((sev) => ({ key: sev as string, list: findings.filter((f) => f.severity === sev && f.status !== "unverified") }));
  groups.push({ key: "unverified", list: findings.filter((f) => f.status === "unverified") });
  return groups.filter((g) => g.list.length);
}

/** The small labels after a finding's place: unverified, fix queued, ignored. */
export function findingTags(f: ReviewFinding): string[] {
  const tags: string[] = [];
  if (f.status === "unverified") tags.push("unverified");
  if (f.fixQueueId) tags.push("fix queued");
  if (f.ignored) tags.push("ignored");
  return tags;
}
