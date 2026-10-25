// Compare page on a change set's card in History: how a page looked before that change set next to
// how it looks now (a queued task; the report lands in .streamhub/Reports/). The page comes from
// comparePage (page-report.ts): the first page the change set changed, else the app's entry page.
import { Images } from "lucide-react";

export function PageCompareButton({
  page,
  busy,
  onCompare,
}: {
  page: string | null;
  busy: boolean;
  onCompare: (page: string) => void;
}) {
  if (!page) return null;
  return (
    <button
      className="flex shrink-0 items-center gap-1 rounded px-1 hover:bg-(--kit-surface-2) hover:text-foreground disabled:opacity-40"
      disabled={busy}
      onClick={() => onCompare(page)}
      title={`Show how ${page} looked before this change set next to how it looks now, changed areas marked`}
      type="button"
    >
      <Images aria-hidden="true" className="h-3.5 w-3.5" />
      Compare page
    </button>
  );
}
