import { languageForPath } from "@/lib/highlight";
import { CodeView } from "./code-block";

type Part = { kind: "text"; text: string } | { kind: "file"; path: string; start: number; code: string };

// File contents in action results: "### PATH (lines A-B of N)" (read) or "Lines A-B of PATH now ..." (edit),
// each followed by the lines in a ```` fence.
const FILE_BLOCK = /^(?:### (\S+)(?: \(lines (\d+)-[^)\n]*\))?|Lines (\d+)-\d+ of (\S+) now[^\n]*)\n````\n([\s\S]*?)\n````$/gm;

/** Splits an action's output into plain text and file contents. */
export function splitActionOutput(output: string): Part[] {
  const parts: Part[] = [];
  let at = 0;
  for (const m of output.matchAll(FILE_BLOCK)) {
    if (m.index > at) parts.push({ kind: "text", text: output.slice(at, m.index) });
    const path = m[1] ?? m[4];
    const start = Number(m[2] ?? m[3] ?? 1);
    parts.push({ kind: "file", path, start, code: m[5] });
    at = m.index + m[0].length;
  }
  if (at < output.length) parts.push({ kind: "text", text: output.slice(at) });
  return parts;
}

/** An action's output: file contents with syntax colors and their real line numbers, the rest as text. */
export function ActionOutput({ output, fallbackPath }: { output: string; fallbackPath?: string }) {
  const parts = splitActionOutput(output.replace(/^~~~~\n?/gm, ""));
  return (
    <div className="max-h-72 overflow-auto rounded-lg bg-black/5 font-mono text-xs dark:bg-white/5">
      {parts.map((p, i) =>
        p.kind === "text" ? (
          p.text.trim() ? (
            <pre className="whitespace-pre-wrap px-3 py-2" key={i}>
              {p.text.trim()}
            </pre>
          ) : null
        ) : (
          <div className="border-black/5 border-t first:border-t-0 dark:border-white/5" key={i}>
            <div className="px-3 pt-1.5 text-[11px] text-muted-foreground">{p.path}</div>
            <CodeView language={languageForPath(p.path || fallbackPath || "")} startLine={p.start} text={p.code} />
          </div>
        )
      )}
    </div>
  );
}
