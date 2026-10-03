/** A small grey "Beta" badge next to a feature's heading. */
export function BetaTag({ title }: { title: string }) {
  return (
    <span className="rounded px-1 py-px font-normal text-[10px] text-muted-foreground uppercase tracking-wide ring-1 ring-black/15 dark:ring-white/20" title={title}>
      Beta
    </span>
  );
}
