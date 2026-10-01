// Line diff (LCS) for approval previews, grouped into hunks with context lines.

export interface DiffLine {
  kind: "same" | "add" | "del";
  text: string;
  oldNo?: number;
  newNo?: number;
}

export type DiffRow = DiffLine | { kind: "gap"; count: number };

const MAX_CELLS = 4_000_000;

export function diffLines(oldText: string, newText: string): DiffLine[] | null {
  const toLines = (t: string) => (t === "" ? [] : t.replace(/\r\n/g, "\n").replace(/\n$/, "").split("\n"));
  const a = toLines(oldText);
  const b = toLines(newText);
  // Trim the common head and tail so the table stays small.
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length - 1;
  let endB = b.length - 1;
  while (endA >= start && endB >= start && a[endA] === b[endB]) {
    endA--;
    endB--;
  }
  const n = endA - start + 1;
  const m = endB - start + 1;
  if (n * m > MAX_CELLS) return null;

  const table: Uint32Array[] = [];
  for (let i = 0; i <= n; i++) table.push(new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      table[i][j] =
        a[start + i] === b[start + j]
          ? table[i + 1][j + 1] + 1
          : Math.max(table[i + 1][j], table[i][j + 1]);
    }
  }

  const out: DiffLine[] = [];
  for (let k = 0; k < start; k++) out.push({ kind: "same", text: a[k], oldNo: k + 1, newNo: k + 1 });
  let i = 0;
  let j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[start + i] === b[start + j]) {
      out.push({ kind: "same", text: a[start + i], oldNo: start + i + 1, newNo: start + j + 1 });
      i++;
      j++;
    } else if (j < m && (i >= n || table[i][j + 1] >= table[i + 1][j])) {
      out.push({ kind: "add", text: b[start + j], newNo: start + j + 1 });
      j++;
    } else {
      out.push({ kind: "del", text: a[start + i], oldNo: start + i + 1 });
      i++;
    }
  }
  for (let k = endA + 1; k < a.length; k++) {
    const nk = k - endA + endB;
    out.push({ kind: "same", text: a[k], oldNo: k + 1, newNo: nk + 1 });
  }
  return out;
}

/** Keeps `context` unchanged lines around each change and folds the rest into gaps. */
export function toHunks(lines: DiffLine[], context = 3): DiffRow[] {
  const keep = new Array<boolean>(lines.length).fill(false);
  lines.forEach((l, idx) => {
    if (l.kind !== "same") {
      for (let k = Math.max(0, idx - context); k <= Math.min(lines.length - 1, idx + context); k++) keep[k] = true;
    }
  });
  const rows: DiffRow[] = [];
  let gap = 0;
  lines.forEach((l, idx) => {
    if (keep[idx]) {
      if (gap) rows.push({ kind: "gap", count: gap });
      gap = 0;
      rows.push(l);
    } else gap++;
  });
  if (gap) rows.push({ kind: "gap", count: gap });
  return rows;
}

export function countChanges(lines: DiffLine[]) {
  let add = 0;
  let del = 0;
  for (const l of lines) {
    if (l.kind === "add") add++;
    else if (l.kind === "del") del++;
  }
  return { add, del };
}

const ACTION_TYPES = new Set(["read", "glob", "grep", "write", "edit", "run", "todo", "done"]);

/** Removes CCBridge action blocks from a reply; they are shown as cards instead. */
export function stripActionBlocks(text: string): string {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const m = /^\s{0,3}(`{3,}|~{3,})\s*([A-Za-z]+)(?:[:\s].*)?$/.exec(lines[i]);
    if (!m) {
      out.push(lines[i]);
      continue;
    }
    const fence = m[1];
    const close = new RegExp(`^\\s{0,3}${fence[0] === "`" ? "`" : "~"}{${fence.length},}\\s*$`);
    let j = i + 1;
    while (j < lines.length && !close.test(lines[j])) j++;
    if (ACTION_TYPES.has(m[2].toLowerCase())) {
      i = j;
    } else {
      for (let k = i; k <= Math.min(j, lines.length - 1); k++) out.push(lines[k]);
      i = j;
    }
  }
  return out.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}
