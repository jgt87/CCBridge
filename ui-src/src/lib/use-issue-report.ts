import { useEffect, useState } from "react";
import { api, type IssueReport } from "@/lib/api";

/**
 * The project's issue report: loaded when the project or its issue details change, and every 3 s
 * while an index run is busy. Kept as it was when no project is open. A failed load is left out:
 * the next poll or the next change loads it again.
 */
export function useIssueReport(project: unknown, issueStamp: string, polling: boolean): IssueReport | null {
  const [report, setReport] = useState<IssueReport | null>(null);
  // The project by its path: the state brings a new project object with every update (several a
  // second), which as a dependency reloaded the report each time.
  const key = project ? String((project as { path?: string }).path ?? "open") : "";
  useEffect(() => {
    if (!key) return;
    const load = () => api.issues().then(setReport, () => undefined);
    load();
    if (!polling) return;
    const t = window.setInterval(load, 3000);
    return () => window.clearInterval(t);
  }, [key, issueStamp, polling]);
  return report;
}
