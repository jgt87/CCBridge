import { useMemo } from "react";
import { countChanges, diffLines, toHunks } from "@/lib/diff";
import type { Preview } from "@/lib/api";
import { cn } from "@/lib/utils";

export function DiffView({ preview }: { preview: Preview }) {
  const lines = useMemo(
    () => diffLines(preview.old ?? "", preview.new ?? ""),
    [preview.old, preview.new]
  );

  if (!lines) {
    return (
      <pre className="max-h-96 overflow-auto rounded-lg bg-black/5 p-3 font-mono text-xs dark:bg-white/5">
        {preview.new}
      </pre>
    );
  }

  const { add, del } = countChanges(lines);
  const rows = preview.exists ? toHunks(lines) : lines;

  return (
    <div className="overflow-hidden rounded-lg border border-black/10 dark:border-white/10">
      <div className="flex items-center justify-between border-black/10 border-b bg-black/[0.03] px-3 py-1.5 text-xs dark:border-white/10 dark:bg-white/[0.03]">
        <span className="font-mono">{preview.path}</span>
        <span>
          {!preview.exists && <span className="mr-2 text-muted-foreground">new file</span>}
          <span className="text-foreground">+{add}</span>{" "}
          <span className="text-rose-500">-{del}</span>
        </span>
      </div>
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
                <tr
                  className={cn(
                    r.kind === "add" && "bg-black/[0.06] dark:bg-white/[0.08]",
                    r.kind === "del" && "bg-rose-500/10"
                  )}
                  key={idx}
                >
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
                    {r.text}
                  </td>
                </tr>
              )
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
