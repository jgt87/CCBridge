import { useMemo, useState } from "react";
import { type DiffLine, type DiffRow, diffLines, toHunks } from "@/lib/diff";
import type { Preview } from "@/lib/api";
import { highlightLines, languageForPath } from "@/lib/highlight";
import { cn } from "@/lib/utils";
import { CodeView } from "./code-block";
import { MarkdownView } from "./markdown-view";

const isMarkdown = (path: string) => /\.(md|markdown)$/i.test(path);

/** How each kind of line looks: the row background, the sign and its colour. */
const LINE_LOOK: Record<DiffLine["kind"], { row?: string; sign: string; signClass: string }> = {
  add: { row: "bg-black/[0.06] dark:bg-white/[0.08]", sign: "+", signClass: "text-foreground" },
  del: { row: "bg-rose-500/10", sign: "-", signClass: "text-rose-500" },
  same: { sign: " ", signClass: "text-transparent" },
};

/** A proposed or applied change: a line diff with syntax colors; Markdown can also be shown rendered.
 *  The +/- counts are on the action card's title row (visible while folded), not repeated here. */
export function DiffView({ preview }: { preview: Preview }) {
  const { md, language, newText, lines, oldHtml, newHtml } = useDiff(preview);
  const [rendered, setRendered] = useState(false);

  let body: React.ReactNode;
  if (md && rendered) body = <MarkdownView className="px-4 py-3" path={preview.path} text={newText} />;
  else if (!lines) body = <CodeView language={language} text={newText} />; // too big to compare line by line: the new text with colors
  else body = <DiffTable newHtml={newHtml} oldHtml={oldHtml} rows={preview.exists ? toHunks(lines) : lines} />;

  return (
    <div className="overflow-hidden rounded-lg border border-black/10 dark:border-white/10">
      <DiffHeader isNew={!preview.exists} markdown={md} onRendered={setRendered} path={preview.path} rendered={rendered} />
      <div className={cn("max-h-[28rem] overflow-auto", lines && !(md && rendered) && "font-mono text-xs leading-5")}>{body}</div>
    </div>
  );
}

/** What a change is made of: its texts, its line diff (null when too big) and the colored lines. */
function useDiff(preview: Preview) {
  const md = isMarkdown(preview.path);
  const language = md ? "markdown" : languageForPath(preview.path);
  const oldText = preview.old ?? "";
  const newText = preview.new ?? "";
  const lines = useMemo(() => diffLines(oldText, newText), [oldText, newText]);
  // Colors come from the whole old and new text, so multi-line comments and strings stay right.
  const oldHtml = useMemo(() => highlightLines(oldText.replace(/\r\n/g, "\n"), language), [oldText, language]);
  const newHtml = useMemo(() => highlightLines(newText.replace(/\r\n/g, "\n"), language), [newText, language]);
  return { md, language, oldText, newText, lines, oldHtml, newHtml };
}

/** The file name, the Changes / Rendered switch for Markdown, and "new file". */
function DiffHeader({ path, markdown, rendered, onRendered, isNew }: { path: string; markdown: boolean; rendered: boolean; onRendered: (on: boolean) => void; isNew: boolean }) {
  const tab = (on: boolean) =>
    cn("rounded px-1.5 py-px", on ? "bg-black/10 text-foreground dark:bg-white/10" : "text-muted-foreground hover:text-foreground");
  return (
    <div className="flex items-center justify-between gap-2 border-black/10 border-b bg-black/[0.03] px-3 py-1.5 text-xs dark:border-white/10 dark:bg-white/[0.03]">
      <span className="min-w-0 truncate font-mono">{path}</span>
      <span className="flex shrink-0 items-center gap-2">
        {markdown && (
          <span className="flex items-center gap-0.5">
            <button className={tab(!rendered)} onClick={() => onRendered(false)} type="button">
              Changes
            </button>
            <button className={tab(rendered)} onClick={() => onRendered(true)} title="The file as it will look" type="button">
              Rendered
            </button>
          </span>
        )}
        {isNew && <span className="text-muted-foreground">new file</span>}
      </span>
    </div>
  );
}

/** The changed lines with old and new line numbers; unchanged runs fold into one gap row. */
function DiffTable({ rows, oldHtml, newHtml }: { rows: DiffRow[]; oldHtml: string[] | null; newHtml: string[] | null }) {
  return (
    <table className="w-full border-collapse">
      <tbody>
        {rows.map((r, idx) =>
          r.kind === "gap" ? (
            <tr className="bg-black/[0.03] text-muted-foreground dark:bg-white/[0.03]" key={idx}>
              <td className="px-3 py-0.5 text-center" colSpan={3}>
                ⋯ {r.count} unchanged line{r.count === 1 ? "" : "s"}
              </td>
            </tr>
          ) : (
            <DiffLineRow html={r.kind === "del" ? oldHtml?.[(r.oldNo ?? 0) - 1] : newHtml?.[(r.newNo ?? 0) - 1]} key={idx} line={r} />
          )
        )}
      </tbody>
    </table>
  );
}

/** One line: its numbers, its +/- sign and its text (colored when the highlighted line is there). */
function DiffLineRow({ line, html }: { line: DiffLine; html: string | undefined }) {
  const look = LINE_LOOK[line.kind];
  return (
    <tr className={cn(look.row)}>
      <td className="w-10 select-none px-2 text-right text-muted-foreground/60">{line.oldNo ?? ""}</td>
      <td className="w-10 select-none px-2 text-right text-muted-foreground/60">{line.newNo ?? ""}</td>
      <td className="whitespace-pre px-2">
        <span className={cn("mr-2 select-none", look.signClass)}>{look.sign}</span>
        <LineText html={html} text={line.text} />
      </td>
    </tr>
  );
}

/** One line: colored when the highlighted line is there (escaped by highlight.js), else plain. */
function LineText({ html, text }: { html: string | undefined; text: string }) {
  if (html === undefined) return <>{text}</>;
  return <span className="hljs" dangerouslySetInnerHTML={{ __html: html }} />;
}
