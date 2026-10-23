// The rules of the command palette's search (components/kokonutui/action-search-bar.tsx):
// which actions match, and how the arrow keys move through them.

type Searchable = { label: string; description?: string };

/** The actions whose label or description holds the query (any case), at most `max`. */
export function filterActions<T extends Searchable>(actions: T[], query: string, max: number): T[] {
  const q = query.toLowerCase().trim();
  const list = q ? actions.filter((a) => `${a.label} ${a.description || ""}`.toLowerCase().includes(q)) : actions;
  return list.slice(0, max);
}

/** Arrow Down: the next row, from the last back to the first. */
export const nextIndex = (prev: number, count: number) => (prev < count - 1 ? prev + 1 : 0);

/** Arrow Up: the row before, from the first to the last. */
export const prevIndex = (prev: number, count: number) => (prev > 0 ? prev - 1 : count - 1);

/** A row's hover text: the whole label and description, which the row may cut off. */
export const actionTitle = (a: Searchable) => (a.description ? `${a.label}: ${a.description}` : a.label);
