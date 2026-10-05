// What StreamHub itself is busy with (the poll's activity). Kept apart from api.ts, which touches
// the page when it loads, so it can be tested on its own.
import type { Activity } from "./api";

/** Whether an activity is the issue index running (older servers send no kind: any label was the index). */
export function isIndexing(a: Activity | null | undefined): boolean {
  return Boolean(a?.label) && (!a?.kind || a.kind === "index");
}
