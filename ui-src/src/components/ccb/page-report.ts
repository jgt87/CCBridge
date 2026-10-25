// Plain helpers for the page report card (Check this page in full) and the Compare page button
// (History), kept apart from the components so Fast refresh keeps working.
import type { AgentEvent } from "@/lib/api";

export interface PageReportItem {
  kind: "pageReport";
  seq: number;
  /** The summary line: the page, how many findings, per kind. */
  text: string;
  /** The report, project-relative (.streamhub/Reports/page-check-...md). */
  path: string;
  /** The findings as one request for Copilot; '' when nothing was found. */
  fixRequest: string;
  restored: boolean;
}

/** The transcript item of a page-report event. */
export function pageReportItem(e: AgentEvent): PageReportItem {
  const x = e as AgentEvent & { fixRequest?: string };
  return { kind: "pageReport", seq: e.seq, text: e.text ?? "", path: e.path ?? "", fixRequest: x.fixRequest ?? "", restored: Boolean(e.restored) };
}

/** Whether the card offers the fix list: findings, not from a restored history, not sent yet. */
export function canSendFixList(item: PageReportItem, sent: boolean, canSend: boolean): boolean {
  return canSend && !sent && !item.restored && item.fixRequest.trim() !== "";
}

const PAGE = /\.html?$/i;

/** The page to compare for a change set: a page it changed (not one it deleted), else the app's entry page. */
export function comparePage(files: string[], appEntry: string | null | undefined, deleted: string[] = []): string | null {
  const gone = new Set(deleted.map((p) => p.toLowerCase()));
  const own = files.map((f) => f.split("\\").join("/")).find((f) => PAGE.test(f) && !gone.has(f.toLowerCase()));
  return own ?? appEntry ?? null;
}
