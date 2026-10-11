import { cn } from "@/lib/utils";

/** Lines added / removed as one pill: green "+n" half and red "-n" half. */
export function ChangePill({ added, removed, className, title }: { added: number; removed: number; className?: string; title?: string }) {
  return (
    <span
      className={cn("inline-flex shrink-0 overflow-hidden rounded-md font-medium font-mono text-[11px] tabular-nums leading-5", className)}
      title={title ?? `${added} line${added === 1 ? "" : "s"} added, ${removed} removed`}
    >
      <span className="bg-(--kit-ok-soft) px-1.5 text-(--kit-ok)">+{added}</span>
      <span className="bg-(--kit-error-soft) px-1.5 text-(--kit-error)">-{removed}</span>
    </span>
  );
}
