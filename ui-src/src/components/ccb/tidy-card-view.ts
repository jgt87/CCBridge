// Texts and grouping of the tidy-up card (components/ccb/tidy-card.tsx). What is listed, and what
// may be removed, is decided by StreamHub (lib/TidyUp.psm1), never here.
import type { TidyItem } from "@/lib/api";

export const TIDY_KINDS: { kind: TidyItem["kind"]; label: string }[] = [
  { kind: "file", label: "Script and style files nothing loads" },
  { kind: "css-rule", label: "Style rules nothing uses" },
  { kind: "data", label: "Data files nothing reads" },
  { kind: "work", label: "Old working files in Work/" },
];

/** A size people read: 512 bytes, 3.4 KB, 1.2 MB. */
export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} bytes`;
  if (bytes < 1024 * 1024) return `${(Math.round((bytes / 1024) * 10) / 10).toString()} KB`;
  return `${(Math.round((bytes / 1024 / 1024) * 10) / 10).toString()} MB`;
}

/** The items by kind, in the card's order; kinds without items left out. */
export function tidyGroups(items: TidyItem[]): { kind: TidyItem["kind"]; label: string; items: TidyItem[] }[] {
  return TIDY_KINDS.map((k) => ({ ...k, items: items.filter((i) => i.kind === k.kind) })).filter((g) => g.items.length);
}

/** One item's name in the list: the file, or the rule and its stylesheet. */
export function tidyItemName(item: TidyItem): string {
  return item.kind === "css-rule" ? `${item.selector} in ${item.path}` : item.path;
}

/** How many are ticked and how much they hold. */
export function selectionSummary(items: TidyItem[], selected: ReadonlySet<string>): { count: number; size: number; text: string } {
  const picked = items.filter((i) => selected.has(i.id));
  const size = picked.reduce((s, i) => s + (Number(i.size) || 0), 0);
  return { count: picked.length, size, text: picked.length ? `${picked.length} selected (${formatSize(size)})` : "Nothing selected" };
}

/** Select all, or none when all are selected already. */
export function toggleAll(items: TidyItem[], selected: ReadonlySet<string>): Set<string> {
  return items.every((i) => selected.has(i.id)) ? new Set() : new Set(items.map((i) => i.id));
}

/** One item ticked or unticked. */
export function toggled(selected: ReadonlySet<string>, id: string): Set<string> {
  const s = new Set(selected);
  if (s.has(id)) s.delete(id);
  else s.add(id);
  return s;
}

/** What the card says once Remove is queued. */
export function tidyQueuedText(count: number): string {
  return `Removing ${count} item(s). Each is checked again first; the chat shows what was removed, and Undo brings it back.`;
}
