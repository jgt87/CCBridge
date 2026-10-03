import { ChevronRight, RotateCcw } from "lucide-react";
import { useState } from "react";
import type { UndoChange } from "@/lib/api";
import { cn } from "@/lib/utils";
import { ChangePill } from "./change-pill";
import { DiffView } from "./diff-view";

/**
 * An undo in the chat: per file, the lines that came back (+) and the lines that went (-), and
 * the diff on click (from the file as it was, to the file as it is again).
 */
export function UndoCard({ text, changes }: { text: string; changes: UndoChange[] }) {
  const [open, setOpen] = useState<string | null>(null);
  const added = changes.reduce((n, c) => n + (c.added ?? 0), 0);
  const removed = changes.reduce((n, c) => n + (c.removed ?? 0), 0);
  return (
    <div className="rounded-xl border border-black/10 bg-card/60 text-sm dark:border-white/10">
      <div className="flex items-center gap-2 px-3 py-2">
        <RotateCcw className="h-4 w-4 shrink-0 text-muted-foreground" />
        <span className="min-w-0 flex-1 truncate font-medium">{text.replace(/:.*$/, "")}</span>
        <ChangePill added={added} removed={removed} />
      </div>
      <div className="border-black/5 border-t px-1.5 py-1 dark:border-white/5">
        {changes.map((c) => {
          const canOpen = Boolean(c.preview) && !c.binary;
          const isOpen = open === c.path;
          return (
            <div key={c.path}>
              <button
                className={cn("flex w-full items-center gap-2 rounded-md px-1.5 py-1 text-left text-xs", canOpen && "hover:bg-black/5 dark:hover:bg-white/5")}
                disabled={!canOpen}
                onClick={() => setOpen(isOpen ? null : c.path)}
                type="button"
              >
                <ChevronRight className={cn("h-3.5 w-3.5 shrink-0 text-muted-foreground transition-transform", isOpen && "rotate-90", !canOpen && "invisible")} />
                <span className="min-w-0 flex-1 truncate font-mono">{c.path}</span>
                {c.deleted && <span className="shrink-0 text-muted-foreground">removed (the step created it)</span>}
                {c.binary ? <span className="shrink-0 text-muted-foreground">restored (not a text file)</span> : <ChangePill added={c.added ?? 0} removed={c.removed ?? 0} />}
              </button>
              {isOpen && c.preview && (
                <div className="px-1.5 pb-2">
                  <DiffView preview={c.preview} />
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
