import { ChevronRight, RotateCcw } from "lucide-react";
import { useState } from "react";
import type { UndoChange } from "@/lib/api";
import { canOpenUndoFile, undoTitle, undoTotals } from "@/lib/undo-view";
import { cn } from "@/lib/utils";
import { ChangePill } from "./change-pill";
import { DiffView } from "./diff-view";

/** One file of an undo: its path, what happened to it, and its diff when open. */
function UndoFileRow({ c, isOpen, onToggle }: { c: UndoChange; isOpen: boolean; onToggle: () => void }) {
  const canOpen = canOpenUndoFile(c);
  return (
    <div>
      <button
        className={cn("flex w-full items-center gap-2 rounded-md px-1.5 py-1 text-left text-xs", canOpen && "hover:bg-(--kit-surface-2)")}
        disabled={!canOpen}
        onClick={onToggle}
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
}

/**
 * An undo in the chat: per file, the lines that came back (+) and the lines that went (-), and
 * the diff on click (from the file as it was, to the file as it is again).
 */
export function UndoCard({ text, changes }: { text: string; changes: UndoChange[] }) {
  const [open, setOpen] = useState<string | null>(null);
  const { added, removed } = undoTotals(changes);
  return (
    <div className="kit-panel p-0 text-sm">
      <div className="flex items-center gap-2 px-3 py-2">
        <RotateCcw className="h-4 w-4 shrink-0 text-muted-foreground" />
        <span className="min-w-0 flex-1 truncate font-medium">{undoTitle(text)}</span>
        <ChangePill added={added} removed={removed} />
      </div>
      <div className="border-(--kit-border) border-t px-1.5 py-1">
        {changes.map((c) => (
          <UndoFileRow c={c} isOpen={open === c.path} key={c.path} onToggle={() => setOpen(open === c.path ? null : c.path)} />
        ))}
      </div>
    </div>
  );
}
