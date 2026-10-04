import { ChevronDown, ChevronRight, FileText, ScanSearch, Wrench } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type { ReviewDetail, ReviewFinding, ReviewSummary } from "@/lib/api";
import { api } from "@/lib/api";
import { cn } from "@/lib/utils";

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";
const field =
  "w-full rounded-md border border-black/10 bg-transparent px-2 py-1 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30";

const FOCUS = ["bugs", "security", "performance", "structure", "readability", "tests"];
const DEFAULT_FOCUS = ["bugs", "security", "performance", "structure"];
const SEVERITY: ReviewFinding["severity"][] = ["high", "medium", "low"];

type Scope = "all" | "changes" | "paths";

/** Code review: Copilot reviews the code read-only; every finding is checked against the file; pick findings to fix. */
export function ReviewPanel({ onOpen, tick }: { onOpen: (path: string) => void; tick: number }) {
  const [scope, setScope] = useState<Scope>("all");
  const [paths, setPaths] = useState("");
  const [focus, setFocus] = useState<string[]>(DEFAULT_FOCUS);
  const [estimate, setEstimate] = useState<{ files: number; messages: number; scopeText: string } | null>(null);
  const [estimateError, setEstimateError] = useState("");
  const [starting, setStarting] = useState(false);
  const [notice, setNotice] = useState("");
  const [reviews, setReviews] = useState<ReviewSummary[]>([]);
  const [openId, setOpenId] = useState<string | null>(null);
  const [detail, setDetail] = useState<ReviewDetail | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [fixing, setFixing] = useState(false);

  const pathList = useMemo(
    () =>
      paths
        .split(/[,\n]/)
        .map((p) => p.trim())
        .filter(Boolean),
    [paths]
  );

  // What the review would take, shown before it starts.
  useEffect(() => {
    setEstimateError("");
    if (scope === "paths" && !pathList.length) {
      setEstimate(null);
      return;
    }
    const t = setTimeout(() => {
      api.reviewEstimate(scope, pathList).then(setEstimate, (e) => {
        setEstimate(null);
        setEstimateError((e as Error).message);
      });
    }, 400);
    return () => clearTimeout(t);
  }, [scope, pathList, tick]);

  useEffect(() => {
    api.reviews().then(setReviews, () => {});
  }, [tick]);

  const load = (id: string) => {
    api.getReview(id).then((r) => {
      setDetail(r);
      setPicked(new Set(r.findings.filter((f) => f.status !== "unverified" && !f.fixQueueId && f.severity !== "low").map((f) => f.id)));
    }, () => setDetail(null));
  };

  useEffect(() => {
    if (openId) load(openId);
  }, [openId, tick]);

  const start = async () => {
    setStarting(true);
    setNotice("");
    try {
      await api.runReview(scope, pathList, focus);
      setNotice("Added to the queue (Tasks tab). Progress shows in the chat; the report appears here.");
    } catch (e) {
      setNotice((e as Error).message);
    } finally {
      setStarting(false);
    }
  };

  const fix = async () => {
    if (!detail) return;
    setFixing(true);
    try {
      const r = await api.fixFindings(detail.id, [...picked]);
      setNotice(`${picked.size} finding(s) added to the queue as ${r.tasks} fix task(s).`);
      load(detail.id);
    } catch (e) {
      setNotice((e as Error).message);
    } finally {
      setFixing(false);
    }
  };

  const toggle = (id: string) =>
    setPicked((cur) => {
      const next = new Set(cur);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  return (
    <div className="space-y-2">
      <div className="space-y-2 rounded-lg border border-black/10 p-2 dark:border-white/10">
        <select aria-label="What to review" className={field} onChange={(e) => setScope(e.target.value as Scope)} value={scope}>
          <option value="all">Whole project</option>
          <option value="changes">Changes since you opened the project</option>
          <option value="paths">Chosen files or folders</option>
        </select>
        {scope === "paths" && <input aria-label="Files or folders to review" className={field} onChange={(e) => setPaths(e.target.value)} placeholder="e.g. src, index.html" value={paths} />}
        <div className="flex flex-wrap gap-1">
          {FOCUS.map((f) => (
            <button
              className={cn(
                "rounded-md border px-1.5 py-0.5 text-xs",
                focus.includes(f) ? "border-black/30 bg-black/10 dark:border-white/30 dark:bg-white/15" : "border-black/10 text-muted-foreground dark:border-white/10"
              )}
              key={f}
              onClick={() => setFocus((cur) => (cur.includes(f) ? cur.filter((x) => x !== f) : [...cur, f]))}
              type="button"
            >
              {f}
            </button>
          ))}
        </div>
        <p className="text-muted-foreground text-xs">
          {estimateError ||
            (estimate
              ? estimate.files
                ? `${estimate.files} file(s), about ${estimate.messages} Copilot message(s). Read-only: nothing is changed.`
                : `No code files in ${estimate.scopeText}.`
              : "Build output, lock files, data and source/ are never reviewed.")}
        </p>
        <button
          className={cn(flatButton, "w-full justify-center border border-black/10 py-1.5 dark:border-white/10")}
          disabled={starting || !estimate?.files || !focus.length}
          onClick={start}
          type="button"
        >
          <ScanSearch className="h-3.5 w-3.5" /> {starting ? "Starting..." : "Start review"}
        </button>
        {notice && <p className="text-muted-foreground text-xs">{notice}</p>}
      </div>

      {reviews.map((r) => (
        <div className="rounded-lg border border-black/10 dark:border-white/10" key={r.id}>
          <button className="flex w-full items-start gap-1.5 p-2 text-left" onClick={() => setOpenId(openId === r.id ? null : r.id)} type="button">
            {openId === r.id ? <ChevronDown className="mt-0.5 h-3.5 w-3.5 shrink-0" /> : <ChevronRight className="mt-0.5 h-3.5 w-3.5 shrink-0" />}
            <span className="min-w-0 flex-1">
              <span className="block text-sm">{new Date(r.created).toLocaleString([], { dateStyle: "medium", timeStyle: "short" })}</span>
              <span className="block truncate text-muted-foreground text-xs">
                {r.scopeText} · {r.high} high · {r.medium} medium · {r.low} low{r.unverified ? ` · ${r.unverified} unverified` : ""}
              </span>
            </span>
          </button>
          {openId === r.id && detail?.id === r.id && (
            <div className="space-y-2 border-black/10 border-t p-2 dark:border-white/10">
              {detail.overall && <p className="text-xs">{detail.overall}</p>}
              <div className="flex flex-wrap gap-1">
                <button className={flatButton} onClick={() => onOpen(r.report)} type="button">
                  <FileText className="h-3 w-3" /> Report
                </button>
                <button className={cn(flatButton, "bg-black/5 dark:bg-white/10")} disabled={!picked.size || fixing} onClick={fix} title="Add coding tasks for the ticked findings to the queue" type="button">
                  <Wrench className="h-3 w-3" /> {fixing ? "Adding..." : `Fix selected (${picked.size})`}
                </button>
              </div>
              {SEVERITY.map((sev) => {
                const list = detail.findings.filter((f) => f.severity === sev && f.status !== "unverified");
                if (!list.length) return null;
                return (
                  <div className="space-y-1" key={sev}>
                    <div className="font-medium text-xs uppercase tracking-wide">{sev}</div>
                    {list.map((f) => (
                      <FindingRow finding={f} key={f.id} onOpen={onOpen} onToggle={() => toggle(f.id)} picked={picked.has(f.id)} />
                    ))}
                  </div>
                );
              })}
              {detail.findings.some((f) => f.status === "unverified") && (
                <div className="space-y-1">
                  <div className="font-medium text-muted-foreground text-xs uppercase tracking-wide" title="Copilot quoted code that is not in the file: these may be mistaken">
                    Unverified
                  </div>
                  {detail.findings
                    .filter((f) => f.status === "unverified")
                    .map((f) => (
                      <FindingRow finding={f} key={f.id} onOpen={onOpen} onToggle={() => toggle(f.id)} picked={picked.has(f.id)} />
                    ))}
                </div>
              )}
              {!detail.findings.length && <p className="text-muted-foreground text-xs">No findings.</p>}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

function FindingRow({ finding: f, picked, onToggle, onOpen }: { finding: ReviewFinding; picked: boolean; onToggle: () => void; onOpen: (path: string) => void }) {
  const [open, setOpen] = useState(false);
  return (
    <div className={cn("rounded-md border border-black/10 p-1.5 dark:border-white/10", f.status === "unverified" && "opacity-60")}>
      <div className="flex items-start gap-1.5">
        <input checked={picked} className="mt-0.5 accent-zinc-500" disabled={Boolean(f.fixQueueId)} onChange={onToggle} title="Fix this finding" type="checkbox" />
        <button className="min-w-0 flex-1 text-left text-xs" onClick={() => setOpen(!open)} type="button">
          <span className="font-medium">{f.title}</span>
          {f.category && <span className="text-muted-foreground"> · {f.category}</span>}
        </button>
      </div>
      <div className="mt-0.5 flex flex-wrap gap-x-2 pl-5 text-muted-foreground text-xs">
        {f.file ? (
          <button className="font-mono hover:underline" onClick={() => onOpen(f.file)} type="button">
            {f.file}
            {f.line ? `:${f.line}` : ""}
          </button>
        ) : (
          <span>whole project</span>
        )}
        {f.status === "unverified" && <span title={f.reason}>unverified</span>}
        {f.fixQueueId && <span>fix queued</span>}
      </div>
      {open && (
        <div className="mt-1 space-y-1 pl-5 text-xs">
          {f.detail && <p>{f.detail}</p>}
          {f.suggestion && <p className="text-muted-foreground">Fix: {f.suggestion}</p>}
          {f.quote && <pre className="overflow-x-auto rounded bg-black/5 p-1 font-mono text-[11px] dark:bg-white/5">{f.quote}</pre>}
        </div>
      )}
    </div>
  );
}
