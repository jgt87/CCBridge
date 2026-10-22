import { ChevronDown, ChevronRight, EyeOff, FileText, ScanSearch, Wrench } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import type { ReviewDetail, ReviewFinding, ReviewSummary } from "@/lib/api";
import { api } from "@/lib/api";
import {
  canStartReview,
  DEFAULT_FOCUS,
  defaultPicked,
  estimateText,
  FOCUS,
  findingGroups,
  findingTags,
  latestOnly,
  type ReviewEstimate,
  reviewCounts,
  splitPaths,
  toggleFocus,
  togglePicked,
} from "@/lib/review-view";
import { cn } from "@/lib/utils";

const flatButton =
  "kit-btn kit-btn--ghost kit-btn--sm";
const field =
  "kit-input h-8 min-h-8 w-full";

type Scope = "all" | "changes" | "paths";

/** Code review: Copilot reviews the code read-only; every finding is checked against the file; pick findings to fix. */
export function ReviewPanel({ onOpen, tick }: { onOpen: (path: string) => void; tick: number }) {
  const [notice, setNotice] = useState("");
  const [reviews, setReviews] = useState<ReviewSummary[]>([]);
  const [openId, setOpenId] = useState<string | null>(null);
  const [detail, setDetail] = useState<ReviewDetail | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [fixing, setFixing] = useState(false);
  // One report opened right after another: only the one opened last may show (lib/review-view.ts).
  const latest = useRef(latestOnly<string, ReviewDetail>()).current;

  useEffect(() => {
    api.reviews().then(setReviews, () => {});
  }, [tick]);

  const load = (id: string) => {
    latest(id, () => api.getReview(id)).then((r) => {
      if (!r) return; // a slower load of a report that is no longer open
      setDetail(r);
      setPicked(defaultPicked(r.findings));
    }, () => setDetail(null));
  };

  useEffect(() => {
    if (openId) load(openId);
  }, [openId, tick]);

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

  const ignore = async (f: ReviewFinding) => {
    if (!detail) return;
    try {
      await api.ignoreFindings(detail.id, [f.id], Boolean(f.ignored));
      load(detail.id);
    } catch (e) {
      setNotice((e as Error).message);
    }
  };

  const toggle = (id: string) => setPicked((cur) => togglePicked(cur, id));

  return (
    <div className="space-y-2">
      <ReviewStarter notice={notice} setNotice={setNotice} tick={tick} />
      {reviews.map((r) => (
        <div className="kit-panel p-0" key={r.id}>
          <ReviewHeader onToggle={() => setOpenId(openId === r.id ? null : r.id)} open={openId === r.id} review={r} />
          {openId === r.id && detail?.id === r.id && (
            <ReviewFindings detail={detail} fixing={fixing} onFix={fix} onIgnore={ignore} onOpen={onOpen} onToggle={toggle} picked={picked} report={r.report} />
          )}
        </div>
      ))}
    </div>
  );
}

/** The form that starts a review: what to review, the focus areas, the estimate and the start button. */
function ReviewStarter({ tick, notice, setNotice }: { tick: number; notice: string; setNotice: (text: string) => void }) {
  const [scope, setScope] = useState<Scope>("all");
  const [paths, setPaths] = useState("");
  const [focus, setFocus] = useState<string[]>(DEFAULT_FOCUS);
  const [estimate, setEstimate] = useState<ReviewEstimate | null>(null);
  const [estimateError, setEstimateError] = useState("");
  const [starting, setStarting] = useState(false);

  const pathList = useMemo(() => splitPaths(paths), [paths]);

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

  const start = async () => {
    setStarting(true);
    setNotice("");
    try {
      await api.runReview(scope, pathList, focus);
      setNotice("Added to Runs (Actions tab). Progress shows in the chat; the report appears here.");
    } catch (e) {
      setNotice((e as Error).message);
    } finally {
      setStarting(false);
    }
  };

  return (
    <div className="kit-panel space-y-2 p-2">
      <select aria-label="What to review" className={field} onChange={(e) => setScope(e.target.value as Scope)} value={scope}>
        <option value="all">Whole project</option>
        <option value="changes">Changes since you opened the project</option>
        <option value="paths">Chosen files or folders</option>
      </select>
      {scope === "paths" && <input aria-label="Files or folders to review" className={field} onChange={(e) => setPaths(e.target.value)} placeholder="e.g. src, index.html" value={paths} />}
      <FocusChips focus={focus} onToggle={(f) => setFocus((cur) => toggleFocus(cur, f))} />
      <p className="text-muted-foreground text-xs">{estimateText(estimateError, estimate)}</p>
      <button
        className={cn(flatButton, "w-full justify-center border border-(--kit-border) py-1.5")}
        disabled={!canStartReview(starting, estimate, focus)}
        onClick={start}
        type="button"
      >
        <ScanSearch className="h-3.5 w-3.5" /> {starting ? "Starting..." : "Start review"}
      </button>
      {notice && <p className="text-muted-foreground text-xs">{notice}</p>}
    </div>
  );
}

/** The focus areas of a review as toggle chips. */
function FocusChips({ focus, onToggle }: { focus: string[]; onToggle: (f: string) => void }) {
  return (
    <div className="flex flex-wrap gap-1">
      {FOCUS.map((f) => (
        <button
          className={cn(
            "rounded-md border px-1.5 py-0.5 text-xs",
            focus.includes(f) ? "border-(--kit-border-strong) bg-(--kit-surface-2)" : "border-(--kit-border) text-muted-foreground"
          )}
          key={f}
          onClick={() => onToggle(f)}
          type="button"
        >
          {f}
        </button>
      ))}
    </div>
  );
}

/** A saved review's row: when it ran and its counts; a click opens or closes its findings. */
function ReviewHeader({ review: r, open, onToggle }: { review: ReviewSummary; open: boolean; onToggle: () => void }) {
  return (
    <button className="flex w-full items-start gap-1.5 p-2 text-left" onClick={onToggle} type="button">
      {open ? <ChevronDown className="mt-0.5 h-3.5 w-3.5 shrink-0" /> : <ChevronRight className="mt-0.5 h-3.5 w-3.5 shrink-0" />}
      <span className="min-w-0 flex-1">
        <span className="block text-sm">{new Date(r.created).toLocaleString([], { dateStyle: "medium", timeStyle: "short" })}</span>
        <span className="block truncate text-muted-foreground text-xs">{reviewCounts(r)}</span>
      </span>
    </button>
  );
}

/** An open review: the overall note, Report and Fix selected, and the findings by severity. */
function ReviewFindings({
  detail,
  report,
  picked,
  fixing,
  onFix,
  onIgnore,
  onOpen,
  onToggle,
}: {
  detail: ReviewDetail;
  report: string;
  picked: Set<string>;
  fixing: boolean;
  onFix: () => void;
  onIgnore: (f: ReviewFinding) => void;
  onOpen: (path: string) => void;
  onToggle: (id: string) => void;
}) {
  return (
    <div className="space-y-2 border-(--kit-border) border-t p-2">
      {detail.overall && <p className="text-xs">{detail.overall}</p>}
      <div className="flex flex-wrap gap-1">
        <button className={flatButton} onClick={() => onOpen(report)} type="button">
          <FileText className="h-3 w-3" /> Report
        </button>
        <button className={cn(flatButton, "bg-(--kit-surface-2)")} disabled={!picked.size || fixing} onClick={onFix} title="Add coding tasks for the ticked findings to the queue" type="button">
          <Wrench className="h-3 w-3" /> {fixing ? "Adding..." : `Fix selected (${picked.size})`}
        </button>
      </div>
      {findingGroups(detail.findings).map((g) => (
        <div className="space-y-1" key={g.key}>
          <GroupHeading group={g.key} />
          {g.list.map((f) => (
            <FindingRow finding={f} key={f.id} onIgnore={() => onIgnore(f)} onOpen={onOpen} onToggle={() => onToggle(f.id)} picked={picked.has(f.id)} />
          ))}
        </div>
      ))}
      {!detail.findings.length && <p className="text-muted-foreground text-xs">No findings.</p>}
    </div>
  );
}

function GroupHeading({ group }: { group: string }) {
  if (group !== "unverified") return <div className="font-medium text-xs uppercase tracking-wide">{group}</div>;
  return (
    <div className="font-medium text-muted-foreground text-xs uppercase tracking-wide" title="Copilot quoted code that is not in the file: these may be mistaken">
      Unverified
    </div>
  );
}

function FindingRow({
  finding: f,
  picked,
  onToggle,
  onOpen,
  onIgnore,
}: {
  finding: ReviewFinding;
  picked: boolean;
  onToggle: () => void;
  onOpen: (path: string) => void;
  onIgnore: () => void;
}) {
  const [open, setOpen] = useState(false);
  const faded = f.status === "unverified" || f.ignored;
  return (
    <div className={cn("rounded-md border border-(--kit-border) p-1.5", faded && "opacity-50")}>
      <div className="flex items-start gap-1.5">
        <input checked={picked && !f.ignored} className="mt-0.5 accent-(--kit-accent)" disabled={Boolean(f.fixQueueId || f.ignored)} onChange={onToggle} title="Fix this finding" type="checkbox" />
        <button className="min-w-0 flex-1 text-left text-xs" onClick={() => setOpen(!open)} type="button">
          <span className="font-medium">{f.title}</span>
          {f.category && <span className="text-muted-foreground"> · {f.category}</span>}
        </button>
      </div>
      <FindingMeta finding={f} onIgnore={onIgnore} onOpen={onOpen} />
      {open && <FindingDetail finding={f} />}
    </div>
  );
}

/** Where a finding is, its state, and Ignore / Unignore for a finding with a quoted line. */
function FindingMeta({ finding: f, onOpen, onIgnore }: { finding: ReviewFinding; onOpen: (path: string) => void; onIgnore: () => void }) {
  return (
    <div className="mt-0.5 flex flex-wrap gap-x-2 pl-5 text-muted-foreground text-xs">
      {f.file ? (
        <button className="kit-link font-mono no-underline hover:underline" onClick={() => onOpen(f.file)} type="button">
          {f.file}
          {f.line ? `:${f.line}` : ""}
        </button>
      ) : (
        <span>whole project</span>
      )}
      {findingTags(f).map((t) => (
        <span key={t} title={t === "unverified" ? f.reason : undefined}>
          {t}
        </span>
      ))}
      {f.file && f.quote && (
        <button
          className="ml-auto inline-flex items-center gap-1 hover:text-foreground"
          onClick={onIgnore}
          title={f.ignored ? "Show this finding again, also in later reviews" : "Not a real problem: hide it here and leave the same line out of later reviews"}
          type="button"
        >
          <EyeOff className="h-3 w-3" /> {f.ignored ? "Unignore" : "Ignore"}
        </button>
      )}
    </div>
  );
}

function FindingDetail({ finding: f }: { finding: ReviewFinding }) {
  return (
    <div className="mt-1 space-y-1 pl-5 text-xs">
      {f.detail && <p>{f.detail}</p>}
      {f.suggestion && <p className="text-muted-foreground">Fix: {f.suggestion}</p>}
      {f.quote && <pre className="kit-code overflow-x-auto p-1 text-[11px]">{f.quote}</pre>}
    </div>
  );
}
