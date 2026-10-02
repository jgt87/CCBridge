import { cn } from "@/lib/utils";

/** Lines added / removed as one pill: green "+n" half and red "-n" half. */
export function ChangePill({ added, removed, className, title }: { added: number; removed: number; className?: string; title?: string }) {
  return (
    <span
      className={cn("inline-flex shrink-0 overflow-hidden rounded-md font-medium font-mono text-[11px] tabular-nums leading-5", className)}
      title={title ?? `${added} line${added === 1 ? "" : "s"} added, ${removed} removed`}
    >
      <span className="bg-emerald-500/15 px-1.5 text-emerald-600 dark:bg-emerald-400/15 dark:text-emerald-400">+{added}</span>
      <span className="bg-rose-500/15 px-1.5 text-rose-600 dark:bg-rose-400/15 dark:text-rose-400">-{removed}</span>
    </span>
  );
}
