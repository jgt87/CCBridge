import { isIndexing } from "@/lib/activity";
import type { Activity } from "@/lib/api";
import { cn } from "@/lib/utils";
import { BetaTag } from "./beta-tag";
import { indexState } from "./index-state";

function indexedAt(updated: string | null) {
  const when = updated ? new Date(updated).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "";
  return `Indexed${when ? ` at ${when}` : ""}`;
}

/** "N file(s) with issues": leads to the issues overview (Code health > Issues) when it can. */
function IssueCount({ withIssues, onShowIssues }: { withIssues: number; onShowIssues?: () => void }) {
  const text = `${withIssues} file(s) with issues`;
  if (!onShowIssues) return <span className="truncate">{text}</span>;
  return (
    <button className="min-w-0 truncate underline-offset-2 hover:text-foreground hover:underline" onClick={onShowIssues} title="Show the issues (Code health tab)" type="button">
      {text}
    </button>
  );
}

function IndexStatus({ activity, files, withIssues, updated, onShowIssues }: IndexBarProps) {
  const state = indexState(isIndexing(activity), files, withIssues);
  if (state === "busy") return <span className="truncate">{`${activity?.label.replace(/ for issues.*$/, "")}...`}</span>;
  if (state === "never") return <span className="truncate">Not indexed yet</span>;
  // Nothing found: only when it was indexed, no issue text.
  if (state === "clean") return <span className="truncate">{indexedAt(updated)}</span>;
  return (
    <>
      <span className="shrink-0">{`${indexedAt(updated)},`}</span>
      <IssueCount onShowIssues={onShowIssues} withIssues={withIssues} />
      <BetaTag title="Beta: still being refined. The checks run without a language model and can miss problems or report ones that are not real." />
    </>
  );
}

interface IndexBarProps {
  activity: Activity | null;
  files: number;
  withIssues: number;
  updated: string | null;
  onShowIssues?: () => void;
}

/** The issue index of the project: a bar that runs left to right while it indexes, and a short status line. */
export function IndexBar(props: IndexBarProps) {
  const { activity } = props;
  const running = isIndexing(activity);
  const pct = running && activity?.total ? Math.min(100, Math.round((activity.done / activity.total) * 100)) : null;
  return (
    <div>
      <div className="flex min-w-0 items-center gap-1 text-muted-foreground text-xs">
        <IndexStatus {...props} />
      </div>
      {/* The bar only while an index run is busy. */}
      {running && (
        <div className="mt-1.5 h-0.5 w-full overflow-hidden rounded-full bg-black/5 dark:bg-white/10">
          <div
            className={cn("h-full rounded-full bg-foreground/60 transition-[width] duration-500", pct === null && "w-1/3 animate-pulse")}
            style={pct === null ? undefined : { width: `${pct}%` }}
          />
        </div>
      )}
    </div>
  );
}
