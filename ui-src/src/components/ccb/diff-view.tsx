import { useMemo, useState } from "react";
import { diffLines, toHunks } from "@/lib/diff";
import type { Preview } from "@/lib/api";
import { highlightLines, languageForPath } from "@/lib/highlight";
import { cn } from "@/lib/utils";
import { CodeView } from "./code-block";
import { MarkdownView } from "./markdown-view";

const isMarkdown = (path: string) => /\.(md|markdown)$/i.test(path);

/** A proposed or applied change: a line diff with syntax colors; Markdown can also be shown rendered.
 *  The +/- counts are on the action card's title row (visible while folded), not repeated here. */
export function DiffView({ preview }: { preview: Preview }) {
  const md = isMarkdown(preview.path);
  const [rendered, setRendered] = useState(false);
  const language = md ? "markdown" : languageForPath(preview.path);
  const lines = useMemo(() => diffLines(preview.old ?? "", preview.new ?? ""), [preview.old, preview.new]);
  // Colors come from the whole old and new text, so multi-line comments and strings stay right.
  const oldHtml = useMemo(() => highlightLines((preview.old ?? "").replace(/\r\n/g, "\n"), language), [preview.old, language]);
  const newHtml = useMemo(() => highlightLines((preview.new ?? "").replace(/\r\n/g, "\n"), language), [preview.new, language]);

  const rows = lines ? (preview.exists ? toHunks(lines) : lines) : [];

  const tab = (on: boolean) =>
    cn("rounded px-1.5 py-px", on ? "bg-black/10 text-foreground dark:bg-white/10" : "text-muted-foreground hover:text-foreground");

  return (
    <div className="overflow-hidden rounded-lg border border-black/10 dark:border-white/10">
      <div className="flex items-center justify-between gap-2 border-black/10 border-b bg-black/[0.03] px-3 py-1.5 text-xs dark:border-white/10 dark:bg-white/[0.03]">
        <span className="min-w-0 truncate font-mono">{preview.path}</span>
        <span className="flex shrink-0 items-center gap-2">
          {md && (
            <span className="flex items-center gap-0.5">
              <button className={tab(!rendered)} onClick={() => setRendered(false)} type="button">
                Changes
              </button>
              <button className={tab(rendered)} onClick={() => setRendered(true)} title="The file as it will look" type="button">
                Rendered
              </button>
            </span>
          )}
          {!preview.exists && <span className="text-muted-foreground">new file</span>}
        </span>
      </div>
      {md && rendered ? (
        <div className="max-h-[28rem] overflow-auto">
          <MarkdownView className="px-4 py-3" path={preview.path} text={preview.new ?? ""} />
        </div>
      ) : !lines ? (
        // Too big to compare line by line: the new text with colors.
        <div className="max-h-[28rem] overflow-auto">
          <CodeView language={language} text={preview.new ?? ""} />
        </div>
      ) : (
        <div className="max-h-[28rem] overflow-auto font-mono text-xs leading-5">
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
                  <tr className={cn(r.kind === "add" && "bg-black/[0.06] dark:bg-white/[0.08]", r.kind === "del" && "bg-rose-500/10")} key={idx}>
                    <td className="w-10 select-none px-2 text-right text-muted-foreground/60">{r.oldNo ?? ""}</td>
                    <td className="w-10 select-none px-2 text-right text-muted-foreground/60">{r.newNo ?? ""}</td>
                    <td className="whitespace-pre px-2">
                      <span
                        className={cn(
                          "mr-2 select-none",
                          r.kind === "add" && "text-foreground",
                          r.kind === "del" && "text-rose-500",
                          r.kind === "same" && "text-transparent"
                        )}
                      >
                        {r.kind === "add" ? "+" : r.kind === "del" ? "-" : " "}
                      </span>
                      <LineText html={r.kind === "del" ? oldHtml?.[(r.oldNo ?? 0) - 1] : newHtml?.[(r.newNo ?? 0) - 1]} text={r.text} />
                    </td>
                  </tr>
                )
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

/** One line: colored when the highlighted line is there (escaped by highlight.js), else plain. */
function LineText({ html, text }: { html: string | undefined; text: string }) {
  if (html === undefined) return <>{text}</>;
  return <span className="hljs" dangerouslySetInnerHTML={{ __html: html }} />;
}
