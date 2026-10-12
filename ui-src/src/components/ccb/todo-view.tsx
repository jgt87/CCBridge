import { Check, Circle, Minus } from "lucide-react";
import { useState } from "react";
import type { Preview } from "@/lib/api";
import type { TodoChange } from "@/lib/todo-list";
import { cn } from "@/lib/utils";
import { DiffView } from "./diff-view";

const TAG: Record<string, string> = { new: "new", checked: "done now", reopened: "reopened" };

/** A to-do file the change wrote: a checklist with what changed, the diff one click away. */
export function TodoView({ todo, preview }: { todo: TodoChange; preview: Preview }) {
  const [diff, setDiff] = useState(false);
  const pct = todo.total ? Math.round((todo.done / todo.total) * 100) : 0;
  let section = "";
  return (
    <div className="kit-panel overflow-hidden p-0">
      <div className="flex items-center gap-3 border-(--kit-border) border-b px-3 py-2">
        <span className="font-medium text-xs">
          {todo.done} of {todo.total} done
        </span>
        <div aria-label={`${pct}% done`} className="kit-progress h-1.5 flex-1" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}>
          <div className="kit-progress__bar" style={{ width: `${pct}%` }} />
        </div>
        <button className="kit-btn kit-btn--ghost kit-btn--sm h-6 min-h-0 px-2 text-xs" onClick={() => setDiff(!diff)} type="button">
          {diff ? "Checklist" : "Changes"}
        </button>
      </div>
      {diff ? (
        <DiffView preview={preview} />
      ) : (
        <ul className="max-h-[28rem] space-y-0.5 overflow-auto px-3 py-2">
          {todo.items.map((it, i) => {
            const head = it.section && it.section !== section ? it.section : "";
            section = it.section || section;
            return (
              <li key={`${i}-${it.text}`}>
                {head && <div className="pt-1.5 pb-0.5 font-medium text-[11px] text-muted-foreground uppercase tracking-wide">{head}</div>}
                <div className="flex items-start gap-2 py-0.5 text-sm" style={{ paddingLeft: `${it.depth * 1.25}rem` }}>
                  {it.done ? (
                    <Check className={cn("mt-0.5 h-3.5 w-3.5 shrink-0", it.change === "checked" ? "text-(--kit-ok)" : "text-muted-foreground")} />
                  ) : (
                    <Circle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted-foreground" />
                  )}
                  <span className={cn("min-w-0 flex-1", it.done && "text-muted-foreground line-through", it.change === "checked" && "text-foreground")}>{it.text}</span>
                  {TAG[it.change] && (
                    <span
                      className={cn(
                        "shrink-0 rounded px-1 font-medium text-[10px] uppercase tracking-wide ring-1",
                        it.change === "checked" ? "bg-(--kit-ok-soft) text-(--kit-ok) ring-transparent" : "text-muted-foreground ring-(--kit-border-strong)"
                      )}
                    >
                      {TAG[it.change]}
                    </span>
                  )}
                </div>
              </li>
            );
          })}
          {todo.removed.map((t) => (
            <li className="flex items-start gap-2 py-0.5 text-muted-foreground text-sm" key={`removed-${t}`}>
              <Minus className="mt-0.5 h-3.5 w-3.5 shrink-0" />
              <span className="min-w-0 flex-1 line-through">{t}</span>
              <span className="shrink-0 rounded px-1 font-medium text-[10px] uppercase tracking-wide ring-1 ring-(--kit-border-strong)">removed</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
