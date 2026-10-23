import type { UndoChange } from "./api";

/** The undo card's title: the undo text up to its first colon (the file list follows it). */
export function undoTitle(text: string): string {
  return text.replace(/:.*$/, "");
}

/** The lines that came back and went, over all files of an undo. */
export function undoTotals(changes: UndoChange[]): { added: number; removed: number } {
  return {
    added: changes.reduce((n, c) => n + (c.added ?? 0), 0),
    removed: changes.reduce((n, c) => n + (c.removed ?? 0), 0),
  };
}

/** A file's diff opens on click only when there is one to show: a text file with a preview. */
export function canOpenUndoFile(c: UndoChange): boolean {
  return Boolean(c.preview) && !c.binary;
}
