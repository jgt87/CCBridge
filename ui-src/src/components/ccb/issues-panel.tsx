import { isIndexing } from "@/lib/activity";
import { ChevronDown, ChevronRight, EyeOff, RefreshCw, Wrench } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import type { Activity, IssueCategory, IssueItem, IssueReport } from "@/lib/api";
import { api } from "@/lib/api";
import {
  fileOpen,
  fixNoticeText,
  fixProgressText,
  ISSUE_CATEGORIES,
  type IssueCounts,
  issueCounts,
  issueMetaText,
  issuesByFile,
  toggled,
  visibleIssues,
} from "@/lib/issues-view";
import { cn } from "@/lib/utils";

const flatButton =
  "kit-btn kit-btn--ghost kit-btn--sm";

function timeOf(s: string | null | undefined) {
  if (!s) return "";
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? s : d.toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
}

/** The index status line: indexing progress while it runs, else what the index holds. */
function IndexStatus({ report, activity }: { report: IssueReport | null; activity?: Activity | null }) {
  if (activity && isIndexing(activity)) {
    return (
      <span>
        {activity.label}
        {activity.total ? ` (${activity.done} of ${activity.total} files)` : "..."}
      </span>
    );
  }
  if (!report?.summary) return <span>Not indexed yet.</span>;
  return (
    <span>
      {report.summary.files} file(s) indexed, updated {timeOf(report.summary.updated)}.
    </span>
  );
}

/** The issue report: loaded on every tick, refreshed while the index runs, with re-index, fix and ignore. */
function useIssues(tick: string, activity: Activity | null | undefined, fixCats: Set<IssueCategory>) {
  const [report, setReport] = useState<IssueReport | null>(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const load = useCallback(() => {
    api.issues().then(
      (r) => {
        setReport(r);
        setError("");
      },
      (e) => setError((e as Error).message)
    );
  }, []);
  useEffect(load, [tick, load]);
  const indexing = isIndexing(activity) || Boolean(report?.indexing.running);
  // While the index runs, refresh now and then so the counts grow.
  useEffect(() => {
    if (!indexing) return;
    const t = window.setInterval(load, 3000);
    return () => window.clearInterval(t);
  }, [indexing, load]);

  const reindex = async () => {
    setNotice("");
    try {
      const r = await api.reindexIssues(true);
      setNotice(r.started ? "Re-indexing all files..." : "An index run is already busy.");
    } catch (e) {
      setError((e as Error).message);
    }
  };
  const fix = async (paths: string[]) => {
    setNotice("");
    try {
      const cats = [...fixCats];
      if (!cats.length) return setNotice("Pick at least one kind of problem to fix.");
      setNotice(fixNoticeText(await api.fixIssues(paths, cats)));
      load();
    } catch (e) {
      setError((e as Error).message);
    }
  };
  const ignore = async (ids: string[], undo: boolean) => {
    try {
      await api.ignoreIssues(ids, undo);
      load();
    } catch (e) {
      setError((e as Error).message);
    }
  };
  return { report, error, notice, indexing, reindex, fix, ignore };
}

/** The filter buttons: one per kind with its open count, and Ignored. */
function IssueFilters({
  show,
  setShow,
  showIgnored,
  setShowIgnored,
  counts,
}: {
  show: Set<IssueCategory>;
  setShow: (s: Set<IssueCategory>) => void;
  showIgnored: boolean;
  setShowIgnored: (v: boolean) => void;
  counts: IssueCounts;
}) {
  return (
    <div className="grid grid-cols-2 gap-1 [&>button]:justify-center">
      {ISSUE_CATEGORIES.map((c) => (
        <button
          className={cn(flatButton, "border border-(--kit-border)", show.has(c.id) ? "bg-(--kit-surface-2)" : "text-muted-foreground")}
          key={c.id}
          onClick={() => setShow(toggled(show, c.id))}
          title={c.help}
          type="button"
        >
          {c.label} {counts[c.id]}
        </button>
      ))}
      <button
        className={cn(flatButton, "border border-(--kit-border)", showIgnored ? "bg-(--kit-surface-2)" : "text-muted-foreground")}
        onClick={() => setShowIgnored(!showIgnored)}
        title="Show ignored problems too"
        type="button"
      >
        Ignored {counts.ignored}
      </button>
    </div>
  );
}

/** Which kinds to fix automatically, and Fix all. */
function FixBox({ fixCats, setFixCats, onFixAll }: { fixCats: Set<IssueCategory>; setFixCats: (s: Set<IssueCategory>) => void; onFixAll: () => void }) {
  return (
    <div className="kit-panel p-2">
      <div className="mb-1 text-muted-foreground text-xs">Fix automatically, one file at a time, scanning each file again afterwards:</div>
      <div className="flex flex-wrap items-center gap-2">
        {ISSUE_CATEGORIES.map((c) => (
          <label className="kit-check text-xs" key={c.id} title={c.help}>
            <input checked={fixCats.has(c.id)} onChange={() => setFixCats(toggled(fixCats, c.id))} type="checkbox" />
            {c.label}
          </label>
        ))}
        <button
          className={cn(flatButton, "ml-auto border border-(--kit-border)")}
          onClick={onFixAll}
          title="Queue a fix task per file with problems of the chosen kinds"
          type="button"
        >
          <Wrench className="h-3.5 w-3.5" /> Fix all
        </button>
      </div>
    </div>
  );
}

/** One problem: its line (opens the file), message, kind and status, and Ignore or Unignore. */
function IssueRow({ item, onOpen, onIgnore }: { item: IssueItem; onOpen: () => void; onIgnore: () => void }) {
  const ignored = item.status === "ignored";
  return (
    <div className={cn("flex items-start gap-2 py-1 text-xs", ignored && "opacity-50")}>
      <button className="kit-link w-10 shrink-0 text-left font-mono text-muted-foreground no-underline hover:underline" onClick={onOpen} title="Open the file" type="button">
        {item.line ? `:${item.line}` : ""}
      </button>
      <div className="min-w-0 flex-1">
        <div className="break-words">{item.message}</div>
        <div className="text-muted-foreground">{issueMetaText(item)}</div>
      </div>
      <button
        className={flatButton}
        onClick={onIgnore}
        title={ignored ? "Show and fix this problem again" : "Not a real problem: hide it and never fix it automatically"}
        type="button"
      >
        <EyeOff className="h-3 w-3" /> {ignored ? "Unignore" : "Ignore"}
      </button>
    </div>
  );
}

/** One file: its name and problem count (click to open the list), Fix, and its problems when open. */
function FileIssues({
  path,
  items,
  isOpen,
  onToggle,
  onFix,
  onOpen,
  onIgnore,
}: {
  path: string;
  items: IssueItem[];
  isOpen: boolean;
  onToggle: () => void;
  onFix: () => void;
  onOpen: (path: string) => void;
  onIgnore: (ids: string[], undo: boolean) => void;
}) {
  const active = items.filter((i) => i.status !== "ignored");
  return (
    <div className="kit-panel p-0">
      <div className="flex items-center gap-1 px-1.5 py-1">
        <button className="flex min-w-0 flex-1 items-center gap-1 text-left" onClick={onToggle} type="button">
          {isOpen ? <ChevronDown className="h-3.5 w-3.5 shrink-0" /> : <ChevronRight className="h-3.5 w-3.5 shrink-0" />}
          <span className="truncate font-mono text-xs">{path}</span>
          <span className="shrink-0 text-muted-foreground text-xs">{items.length}</span>
        </button>
        <button className={flatButton} disabled={!active.length} onClick={onFix} title="Queue a fix task for this file (the kinds ticked above)" type="button">
          <Wrench className="h-3 w-3" /> Fix
        </button>
      </div>
      {isOpen && (
        <div className="border-(--kit-border) border-t px-2 py-1">
          {items.map((i) => (
            <IssueRow item={i} key={i.id} onIgnore={() => onIgnore([i.id], i.status === "ignored")} onOpen={() => onOpen(path)} />
          ))}
        </div>
      )}
    </div>
  );
}

/** Issues: what the file checks, secret scan and code-health limits found, per file, with fix and ignore. */
export function IssuesPanel({ onOpen, tick, activity }: { onOpen: (path: string) => void; tick: string; activity?: Activity | null }) {
  const [show, setShow] = useState<Set<IssueCategory>>(new Set(["error", "secret", "health"]));
  const [showIgnored, setShowIgnored] = useState(false);
  const [fixCats, setFixCats] = useState<Set<IssueCategory>>(new Set(["error"]));
  const [open, setOpen] = useState<Set<string>>(new Set());
  const [allOpen, setAllOpen] = useState(false);
  const { report, error, notice, indexing, reindex, fix, ignore } = useIssues(tick, activity, fixCats);

  const byFile = useMemo(() => issuesByFile(visibleIssues(report?.items ?? [], show, showIgnored)), [report, show, showIgnored]);
  const counts = useMemo(() => issueCounts(report?.items ?? []), [report]);
  const progress = fixProgressText(counts);

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center justify-between gap-2">
        <div className="min-w-0 text-muted-foreground text-xs">
          <IndexStatus activity={activity} report={report} />
        </div>
        <button className={cn(flatButton, "shrink-0")} disabled={indexing} onClick={reindex} title="Scan every file again" type="button">
          <RefreshCw className={cn("h-3.5 w-3.5", indexing && "animate-spin")} /> Re-index
        </button>
      </div>
      {error && <div className="kit-error-text">{error}</div>}

      <IssueFilters counts={counts} setShow={setShow} setShowIgnored={setShowIgnored} show={show} showIgnored={showIgnored} />
      {progress && <div className="text-muted-foreground text-xs">{progress}</div>}

      <FixBox fixCats={fixCats} onFixAll={() => fix([])} setFixCats={setFixCats} />
      {notice && <div className="text-muted-foreground text-xs">{notice}</div>}

      {byFile.length > 0 && (
        <button className={cn(flatButton, "self-start text-muted-foreground")} onClick={() => { setAllOpen(!allOpen); setOpen(new Set()); }} type="button">
          {allOpen ? "Collapse all" : "Expand all"}
        </button>
      )}
      <div className="flex flex-col gap-1">
        {byFile.map(([path, items]) => (
          <FileIssues
            isOpen={fileOpen(path, allOpen, open)}
            items={items}
            key={path}
            onFix={() => fix([path])}
            onIgnore={ignore}
            onOpen={onOpen}
            onToggle={() => setOpen(toggled(open, path))}
            path={path}
          />
        ))}
      </div>

    </div>
  );
}
