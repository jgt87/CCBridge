import { Info } from "lucide-react";
import type React from "react";
import { cn } from "@/lib/utils";

/** A visible note that something only runs while StreamHub is open (schedules, the queue). */
export function KeepOpenNote({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <div className={cn("kit-notice px-2.5 py-2 text-xs", className)}>
      <Info className="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted-foreground" />
      <span>{children}</span>
    </div>
  );
}

export const SCHEDULE_NOTE =
  "Schedules run only while StreamHub is open (its window or tab may be in the background). A run that falls while StreamHub is closed runs once at the next start.";

export const QUEUE_NOTE =
  "Waiting tasks run one after another while StreamHub is open. If you close it, they continue at the next start; a task that was running then has to be sent again.";
