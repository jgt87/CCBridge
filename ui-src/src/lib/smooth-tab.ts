/** Layout rules of the tab bar (components/kokonutui/smooth-tab.tsx). */

/** Columns of the tab grid: `columns` when given, else one row; at least 1, at most the number of tabs. */
export function gridColumns(columns: number | undefined, count: number): number {
  return Math.max(1, Math.min(columns ?? count, count));
}

/** The columns the last tab spans beyond its own: the room its row leaves free (for a badge); 0 for the others. */
export function spareColumns(index: number, count: number, cols: number): number {
  return index === count - 1 ? (cols - (count % cols)) % cols : 0;
}

/** The way the panel slides: 1 when the new tab lies after the current one, else -1. */
export function slideDirection(ids: string[], from: string, to: string): number {
  return ids.indexOf(to) > ids.indexOf(from) ? 1 : -1;
}

/** The fill colour of the decorative card from a tab's colour classes ("bg-blue-500 hover:..." -> "blue-500"). */
export function fillClassOf(color: string): string {
  return color.split(" ").at(0)?.replace("bg-", "") ?? "blue-500";
}
