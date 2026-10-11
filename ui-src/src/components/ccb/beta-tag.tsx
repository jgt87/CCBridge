/** A small grey "Beta" badge next to a feature's heading. */
export function BetaTag({ title }: { title: string }) {
  return (
    <span className="kit-badge min-h-0 px-1 py-px font-normal text-[10px] uppercase tracking-wide" title={title}>
      Beta
    </span>
  );
}
