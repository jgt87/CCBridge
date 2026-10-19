import { useCallback, useEffect, useState } from "react";
import { api, type ChainItem, type FetchItem, type FileInfo, type RunbookItem, type RunbookTemplate } from "@/lib/api";

// A failed list refresh keeps the lists as they were: the next change, focus or busy tick asks again,
// and a lost server shows through the poll's error bar.
const keep = () => {};

/** The project's file tree and the lists that follow its files (runbooks, fetches, chains, scripts). */
export function useProjectLists(projectPath: string | undefined, busy: boolean) {
  const [files, setFiles] = useState<FileInfo[]>([]);
  const [fetchItems, setFetchItems] = useState<FetchItem[]>([]);
  const [runbooks, setRunbooks] = useState<RunbookItem[]>([]);
  const [runbookTemplates, setRunbookTemplates] = useState<RunbookTemplate[]>([]);
  const [chains, setChains] = useState<ChainItem[]>([]);
  const [scripts, setScripts] = useState<string[]>([]);

  // The file tree: a refresh after a change shows a bar in the Files tab (at least 600 ms, so it is
  // seen); the background refresh while StreamHub works is silent ({ quiet: true }).
  const [filesRefreshing, setFilesRefreshing] = useState(false);
  const refreshFiles = useCallback((opts?: { quiet?: boolean }) => {
    const shown = !opts?.quiet;
    const started = Date.now();
    if (shown) setFilesRefreshing(true);
    api.files().then((r) => setFiles(r.files), keep).finally(() => {
      if (shown) window.setTimeout(() => setFilesRefreshing(false), Math.max(0, 600 - (Date.now() - started)));
    });
    // The lists of runbooks, fetches and chains change with files Copilot or the person writes:
    // after such a change (not quiet) and on focus, never with the timer while StreamHub works.
    if (opts?.quiet) return;
    api.fetchList().then(setFetchItems, keep);
    api.runbooks().then((r) => {
      setRunbooks(r.runbooks);
      setRunbookTemplates(r.templates);
    }, keep);
    api.chains().then((r) => {
      setChains(r.chains);
      setScripts(r.scripts);
    }, keep);
  }, []);

  useEffect(() => {
    if (projectPath) refreshFiles();
  }, [projectPath, refreshFiles]);

  // While StreamHub works, the tree also refreshes every few seconds (a command may write files
  // before its result comes back); coming back to the window picks up files changed elsewhere.
  useEffect(() => {
    if (!projectPath || !busy) return;
    const t = window.setInterval(() => refreshFiles({ quiet: true }), 4000);
    return () => window.clearInterval(t);
  }, [projectPath, busy, refreshFiles]);
  useEffect(() => {
    const onFocus = () => projectPath && refreshFiles();
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [projectPath, refreshFiles]);

  return { files, fetchItems, runbooks, runbookTemplates, chains, scripts, filesRefreshing, refreshFiles };
}
