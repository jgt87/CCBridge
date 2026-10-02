import { CalendarClock, ChevronRight, Plus, X } from "lucide-react";
import { ModalBackdrop } from "./modal-backdrop";
import { useEffect, useState } from "react";
import type { FetchItem, FileInfo, RunbookItem, ScheduleItem, ScheduleSpec } from "@/lib/api";
import { cn } from "@/lib/utils";
import { ScheduleForm, type ScheduleTarget } from "./schedule-form";
import { formatWhen, SchedulesList } from "./schedules-panel";

/** The Scheduled entry in the Tasks tab: how many schedules and the next run; opens the modal. */
export function SchedulesSummary({ schedules, onOpen }: { schedules: ScheduleItem[]; onOpen: () => void }) {
  const active = schedules.filter((s) => s.enabled && s.nextRun);
  const next = [...active].sort((a, b) => String(a.nextRun).localeCompare(String(b.nextRun)))[0];
  return (
    <button
      className="flex w-full items-center gap-2 rounded-lg border border-black/10 p-2 text-left hover:bg-black/5 dark:border-white/10 dark:hover:bg-white/5"
      onClick={onOpen}
      title="Open the schedules"
      type="button"
    >
      <CalendarClock className="h-4 w-4 shrink-0 text-muted-foreground" />
      <span className="min-w-0 flex-1">
        <span className="block font-medium text-sm">Scheduled</span>
        <span className="block truncate text-muted-foreground text-xs">
          {schedules.length === 0
            ? "Run messages, fetches and runbooks on set days and times"
            : `${active.length} active${schedules.length > active.length ? `, ${schedules.length - active.length} paused or done` : ""}${next ? ` · next ${formatWhen(next.nextRun)}` : ""}`}
        </span>
      </span>
      <ChevronRight className="h-4 w-4 shrink-0 text-muted-foreground" />
    </button>
  );
}

/** Schedules in a modal: the list with run now / pause / delete, and the form for a new one. */
export function SchedulesModal({
  schedules,
  fetchItems,
  runbooks,
  files,
  initial,
  onCreate,
  onClose,
}: {
  schedules: ScheduleItem[];
  fetchItems: FetchItem[];
  runbooks: RunbookItem[];
  files: FileInfo[];
  /** Opened to schedule something specific (from the message box, a runbook or a fetch prompt). */
  initial: ScheduleTarget | null;
  onCreate: (spec: ScheduleSpec) => Promise<void>;
  onClose: () => void;
}) {
  const [target, setTarget] = useState<ScheduleTarget | null>(initial);
  useEffect(() => setTarget(initial), [initial]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && !e.defaultPrevented && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <ModalBackdrop onClose={onClose}>
      <div
        className="flex max-h-[80vh] w-full max-w-xl flex-col overflow-hidden rounded-xl border border-black/10 bg-background shadow-xl dark:border-white/10"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex shrink-0 items-center justify-between gap-2 border-black/10 border-b px-4 py-3 dark:border-white/10">
          <div className="min-w-0">
            <div className="font-semibold">Scheduled</div>
            <div className="text-muted-foreground text-xs">Messages, fetches and runbooks that run on set days and times while StreamHub is open.</div>
          </div>
          <div className="flex shrink-0 items-center gap-1">
            {!target && (
              <button
                className="inline-flex items-center gap-1 rounded-md border border-black/10 px-2 py-1 text-xs hover:bg-black/5 dark:border-white/10 dark:hover:bg-white/5"
                onClick={() => setTarget({ kind: runbooks.length ? "runbook" : "chat", name: runbooks[0]?.name })}
                type="button"
              >
                <Plus className="h-3.5 w-3.5" /> New schedule
              </button>
            )}
            <button className="rounded p-1 hover:bg-black/5 dark:hover:bg-white/5" onClick={onClose} title="Close (Esc)" type="button">
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>
        <div className={cn("min-h-0 flex-1 overflow-y-auto p-4")}>
          {target ? (
            <ScheduleForm
              fetchItems={fetchItems}
              files={files}
              initial={target}
              key={JSON.stringify(target)}
              onCancel={() => (initial ? onClose() : setTarget(null))}
              onSave={async (spec) => {
                await onCreate(spec);
                setTarget(null);
              }}
              runbooks={runbooks}
            />
          ) : (
            <SchedulesList schedules={schedules} />
          )}
        </div>
      </div>
    </ModalBackdrop>
  );
}
