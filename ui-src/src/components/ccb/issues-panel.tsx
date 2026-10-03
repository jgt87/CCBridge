import { ChevronDown, ChevronRight, EyeOff, RefreshCw, Wrench } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import type { Activity, IssueCategory, IssueItem, IssueReport } from "@/lib/api";
import { api } from "@/lib/api";
import { cn } from "@/lib/utils";

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";

const CATEGORIES: { id: IssueCategory; label: string; help: string }[] = [
  { id: "error", label: "Errors", help: "Broken syntax, unclosed blocks or strings, missing local files, unknown commands" },
  { id: "secret", label: "Secrets", help: "Keys, tokens and passwords written in the code" },
  { id: "health", label: "Code health", help: "Functions that are very complex, very deeply nested or very long" },
];

const STATUS_TEXT: Record<IssueItem["status"], string> = { open: "open", fixing: "fixing", "gave up": "gave up", ignored: "ignored" };

function timeOf(s: string | null | undefined) {
  if (!s) return "";
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? s : d.toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
}

/** The index status line: indexing progress while it runs, else what the index holds. */
function IndexStatus({ report, activity }: { report: IssueReport | null; activity?: Activity | null }) {
  if (activity?.label) {
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

/** Issues: what the file checks, secret scan and code-health limits found, per file, with fix and ignore. */
export function IssuesPanel({ onOpen, tick, activity }: { onOpen: (path: string) => void; tick: string; activity?: Activity | null }) {
  const [report, setReport] = useState<IssueReport | null>(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [show, setShow] = useState<Set<IssueCategory>>(new Set(["error", "secret", "health"]));
  const [showIgnored, setShowIgnored] = useState(false);
  const [fixCats, setFixCats] = useState<Set<IssueCategory>>(new Set(["error"]));
  const [open, setOpen] = useState<Set<string>>(new Set());
  const [allOpen, setAllOpen] = useState(false);

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
  const indexing = Boolean(activity?.label) || Boolean(report?.indexing.running);
  // While the index runs, refresh now and then so the counts grow.
  useEffect(() => {
    if (!indexing) return;
    const t = window.setInterval(load, 3000);
    return () => window.clearInterval(t);
  }, [indexing, load]);

  const visible = useMemo(
    () => (report?.items ?? []).filter((i) => show.has(i.category) && (showIgnored ? true : i.status !== "ignored")),
    [report, show, showIgnored]
  );
  const byFile = useMemo(() => {
    const m = new Map<string, IssueItem[]>();
    for (const i of visible) m.set(i.path, [...(m.get(i.path) ?? []), i]);
    return [...m.entries()];
  }, [visible]);
  const counts = useMemo(() => {
    const c = { error: 0, secret: 0, health: 0, fixing: 0, gaveUp: 0, ignored: 0 };
    for (const i of report?.items ?? []) {
      if (i.status === "ignored") c.ignored++;
      else if (i.status === "fixing") c.fixing++;
      else if (i.status === "gave up") c.gaveUp++;
      else c[i.category]++;
    }
    return c;
  }, [report]);

  const toggle = <T,>(set: Set<T>, v: T) => {
    const n = new Set(set);
    if (n.has(v)) n.delete(v);
    else n.add(v);
    return n;
  };

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
      const r = await api.fixIssues(paths, cats);
      setNotice(r.queued ? `Queued ${r.queued} fix task(s) for ${r.issues} problem(s); each file is scanned again afterwards.` : "Nothing to fix for the chosen kinds.");
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

  const others = (report?.projects ?? []).filter((p) => p.root !== report?.summary?.root);

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
      {error && <div className="text-rose-500 text-xs">{error}</div>}

      <div className="grid grid-cols-2 gap-1 [&>button]:justify-center">
        {CATEGORIES.map((c) => (
          <button
            className={cn(flatButton, "border border-black/10 dark:border-white/10", show.has(c.id) ? "bg-black/5 dark:bg-white/10" : "text-muted-foreground")}
            key={c.id}
            onClick={() => setShow(toggle(show, c.id))}
            title={c.help}
            type="button"
          >
            {c.label} {counts[c.id]}
          </button>
        ))}
        <button
          className={cn(flatButton, "border border-black/10 dark:border-white/10", showIgnored ? "bg-black/5 dark:bg-white/10" : "text-muted-foreground")}
          onClick={() => setShowIgnored(!showIgnored)}
          title="Show ignored problems too"
          type="button"
        >
          Ignored {counts.ignored}
        </button>
      </div>
      {(counts.fixing > 0 || counts.gaveUp > 0) && (
        <div className="text-muted-foreground text-xs">
          {counts.fixing > 0 && `${counts.fixing} being fixed. `}
          {counts.gaveUp > 0 && `${counts.gaveUp} still there after the fix attempts (gave up).`}
        </div>
      )}

      <div className="rounded-lg border border-black/10 p-2 dark:border-white/10">
        <div className="mb-1 text-muted-foreground text-xs">Fix automatically, one file at a time, scanning each file again afterwards:</div>
        <div className="flex flex-wrap items-center gap-2">
          {CATEGORIES.map((c) => (
            <label className="flex items-center gap-1 text-xs" key={c.id} title={c.help}>
              <input checked={fixCats.has(c.id)} className="accent-zinc-500" onChange={() => setFixCats(toggle(fixCats, c.id))} type="checkbox" />
              {c.label}
            </label>
          ))}
          <button
            className={cn(flatButton, "ml-auto border border-black/10 dark:border-white/10")}
            onClick={() => fix([])}
            title="Queue a fix task per file with problems of the chosen kinds"
            type="button"
          >
            <Wrench className="h-3.5 w-3.5" /> Fix all
          </button>
        </div>
      </div>
      {notice && <div className="text-muted-foreground text-xs">{notice}</div>}

      {byFile.length > 0 && (
        <button className={cn(flatButton, "self-start text-muted-foreground")} onClick={() => { setAllOpen(!allOpen); setOpen(new Set()); }} type="button">
          {allOpen ? "Collapse all" : "Expand all"}
        </button>
      )}
      {byFile.length === 0 && report && !indexing && <div className="text-muted-foreground text-xs">No problems of the shown kinds.</div>}
      <div className="flex flex-col gap-1">
        {byFile.map(([path, items]) => {
          const isOpen = allOpen ? !open.has(path) : open.has(path);
          const active = items.filter((i) => i.status !== "ignored");
          return (
            <div className="rounded-lg border border-black/10 dark:border-white/10" key={path}>
              <div className="flex items-center gap-1 px-1.5 py-1">
                <button className="flex min-w-0 flex-1 items-center gap-1 text-left" onClick={() => setOpen(toggle(open, path))} type="button">
                  {isOpen ? <ChevronDown className="h-3.5 w-3.5 shrink-0" /> : <ChevronRight className="h-3.5 w-3.5 shrink-0" />}
                  <span className="truncate font-mono text-xs">{path}</span>
                  <span className="shrink-0 text-muted-foreground text-xs">{items.length}</span>
                </button>
                <button className={flatButton} disabled={!active.length} onClick={() => fix([path])} title="Queue a fix task for this file (the kinds ticked above)" type="button">
                  <Wrench className="h-3 w-3" /> Fix
                </button>
              </div>
              {isOpen && (
                <div className="border-black/10 border-t px-2 py-1 dark:border-white/10">
                  {items.map((i) => (
                    <div className={cn("flex items-start gap-2 py-1 text-xs", i.status === "ignored" && "opacity-50")} key={i.id}>
                      <button className="w-10 shrink-0 text-left font-mono text-muted-foreground hover:underline" onClick={() => onOpen(path)} title="Open the file" type="button">
                        {i.line ? `:${i.line}` : ""}
                      </button>
                      <div className="min-w-0 flex-1">
                        <div className="break-words">{i.message}</div>
                        <div className="text-muted-foreground">
                          {CATEGORIES.find((c) => c.id === i.category)?.label} · {STATUS_TEXT[i.status]}
                          {i.attempts > 0 && ` · ${i.attempts} attempt(s)`}
                          {i.note && ` · ${i.note}`}
                        </div>
                      </div>
                      <button
                        className={flatButton}
                        onClick={() => ignore([i.id], i.status === "ignored")}
                        title={i.status === "ignored" ? "Show and fix this problem again" : "Not a real problem: hide it and never fix it automatically"}
                        type="button"
                      >
                        <EyeOff className="h-3 w-3" /> {i.status === "ignored" ? "Unignore" : "Ignore"}
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>
          );
        })}
      </div>

      {others.length > 0 && (
        <div className="pt-1">
          <div className="text-muted-foreground text-xs uppercase tracking-wide">All projects</div>
          {others.map((p) => (
            <div className="flex items-center justify-between gap-2 py-0.5 text-xs" key={p.root} title={p.root}>
              <span className="truncate">{p.name}</span>
              <span className="shrink-0 text-muted-foreground">
                {p.open.error} errors · {p.open.secret} secrets · {p.open.health} health · {timeOf(p.updated)}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
