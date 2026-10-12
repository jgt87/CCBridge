/**
 * To-do lists in a change (TODO.md, PLAN.md, TASKS.md, or any Markdown file that is mostly
 * "- [ ]" items): the items with what this change did to each, so the card can show a checklist
 * instead of lines added and removed.
 */

export interface TodoItem {
  text: string;
  done: boolean;
  /** Nesting: 0 for a top-level item. */
  depth: number;
  /** The heading the item stands under, if any. */
  section: string;
  /** What this change did: new item, checked off, checked again (reopened), or nothing. */
  change: "new" | "checked" | "reopened" | "same";
}

export interface TodoChange {
  items: TodoItem[];
  /** Items the change took out. */
  removed: string[];
  done: number;
  total: number;
}

const ITEM = /^(\s*)(?:[-*+]|\d+[.)])\s+\[([ xX])\]\s+(.+?)\s*$/;
const HEADING = /^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$/;
const NAMED = /(^|\/)(todo|to-do|tasks?|plan|checklist|roadmap)[^/]*\.(md|markdown|txt)$/i;

function parse(text: string): Omit<TodoItem, "change">[] {
  const out: Omit<TodoItem, "change">[] = [];
  let section = "";
  let fence = false;
  for (const line of text.replace(/\r\n/g, "\n").split("\n")) {
    if (/^\s*(```|~~~)/.test(line)) { fence = !fence; continue; }
    if (fence) continue;
    const h = HEADING.exec(line);
    if (h) { section = h[1]; continue; }
    const m = ITEM.exec(line);
    if (m) out.push({ text: m[3].replace(/~~/g, ""), done: m[2] !== " ", depth: Math.floor(m[1].replace(/\t/g, "  ").length / 2), section });
  }
  return out;
}

const key = (t: string) => t.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();

/** Whether a file change is a to-do list: by its name, or by its text (two or more items, most lines items). */
export function isTodoChange(path: string, text: string): boolean {
  if (!/\.(md|markdown|txt)$/i.test(path)) return false;
  const items = parse(text);
  if (items.length < 2) return false;
  if (NAMED.test(path)) return true;
  const lines = text.split(/\r?\n/).filter((l) => l.trim() && !HEADING.test(l));
  return items.length / Math.max(1, lines.length) >= 0.6;
}

/** The items of the new text with what the change did to each, and the items it took out. */
export function todoChange(oldText: string, newText: string): TodoChange {
  const before = new Map<string, boolean>();
  for (const it of parse(oldText)) before.set(key(it.text), it.done);
  const items: TodoItem[] = parse(newText).map((it) => {
    const k = key(it.text);
    const was = before.get(k);
    before.delete(k);
    const change = was === undefined ? "new" : was === it.done ? "same" : it.done ? "checked" : "reopened";
    return { ...it, change };
  });
  const removed = parse(oldText).filter((it) => before.has(key(it.text))).map((it) => it.text);
  return { items, removed, done: items.filter((i) => i.done).length, total: items.length };
}
