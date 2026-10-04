import { CalendarClock, Pause, Pencil, Play, Trash2 } from "lucide-react";
import type { ScheduleItem } from "@/lib/api";
import { api } from "@/lib/api";
import { cn } from "@/lib/utils";

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";

const KIND: Record<ScheduleItem["kind"], string> = { chat: "Message", fetch: "Runbook", runbook: "Runbook", chain: "Chain", script: "Script" };

/** "today 08:00", "tomorrow 13:00", "Mon 6 Oct 08:00". */
export function formatWhen(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  const time = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const day = new Date(d);
  day.setHours(0, 0, 0, 0);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const diff = Math.round((day.getTime() - today.getTime()) / 86400000);
  if (diff === 0) return `today ${time}`;
  if (diff === 1) return `tomorrow ${time}`;
  return `${d.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" })} ${time}`;
}

/** Scheduled messages, runbooks and chains, with the next run, edit, run now, pause and delete. */
export function SchedulesList({ schedules, onEdit }: { schedules: ScheduleItem[]; onEdit?: (s: ScheduleItem) => void }) {
  return (
    <div className="space-y-1.5">
      {schedules.length === 0 && <p className="text-muted-foreground text-sm">Nothing scheduled yet. Use New schedule, or the calendar button in the message box.</p>}
      {schedules.map((s) => {
        const finished = !s.enabled && s.repeat === "once" && s.lastRun;
        return (
          <div className={cn("rounded-lg border border-black/10 p-2 dark:border-white/10", !s.enabled && "opacity-60")} key={s.id}>
            <div className="flex items-start gap-2">
              <CalendarClock className="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted-foreground" />
              <span className="line-clamp-2 min-w-0 flex-1 text-sm" title={s.title}>
                {s.title}
              </span>
            </div>
            <div className="mt-1 flex flex-wrap gap-x-2 gap-y-0.5 pl-5 text-muted-foreground text-xs">
              <span>{KIND[s.kind]}</span>
              <span>{s.when}</span>
              {s.project && <span className="truncate">{s.project}</span>}
            </div>
            <div className="mt-0.5 pl-5 text-muted-foreground text-xs">
              {finished
                ? `ran ${formatWhen(s.lastRun)}`
                : s.enabled
                  ? `next ${formatWhen(s.nextRun)}`
                  : "paused"}
            </div>
            <div className="mt-1 flex flex-wrap gap-0.5 pl-4">
              {onEdit && (
                <button className={flatButton} onClick={() => onEdit(s)} title="Change what it runs, when, or its title" type="button">
                  <Pencil className="h-3 w-3" /> Edit
                </button>
              )}
              <button className={flatButton} onClick={() => api.runSchedule(s.id)} title="Add it to the queue now (the schedule stays as it is)" type="button">
                <Play className="h-3 w-3" /> Run now
              </button>
              {!finished && (
                <button className={flatButton} onClick={() => api.updateSchedule(s.id, { enabled: !s.enabled })} type="button">
                  <Pause className="h-3 w-3" /> {s.enabled ? "Pause" : "Resume"}
                </button>
              )}
              <button className={flatButton} onClick={() => api.deleteSchedule(s.id)} title="Delete this schedule" type="button">
                <Trash2 className="h-3 w-3" /> Delete
              </button>
            </div>
          </div>
        );
      })}
    </div>
  );
}
