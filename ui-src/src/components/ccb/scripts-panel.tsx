import { CalendarClock, FileCode2, Play } from "lucide-react";

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";

/**
 * Automation > Scripts: the project's scripts (Scripts/*.ps1, .cmd, .bat, .py), run on their own
 * or on a schedule, with the same rules as a script step in a chain.
 */
export function ScriptsPanel({
  scripts,
  busy,
  onRun,
  onSchedule,
  onOpen,
}: {
  scripts: string[];
  busy: boolean;
  onRun: (path: string) => void;
  onSchedule?: (path: string) => void;
  onOpen: (path: string) => void;
}) {
  return (
    <div className="space-y-2">
      <p className="text-muted-foreground text-xs">
        Scripts in <span className="font-mono">Scripts/</span> (.ps1, .cmd, .bat, .py) that run in the project folder. A script is approved the first time it runs and again after it
        changes; one that deletes data or uses Microsoft 365 asks every time. What it changes can be undone in History.
      </p>
      {scripts.length === 0 && <p className="text-muted-foreground text-xs">No scripts yet: put a script in Scripts/ (or ask Copilot to write one) and it shows here.</p>}
      {scripts.map((path) => (
        <div className="rounded-lg border border-black/10 p-2 dark:border-white/10" key={path}>
          <div className="truncate font-mono text-xs" title={path}>
            {path.replace(/^Scripts\//i, "")}
          </div>
          <div className="mt-1.5 flex flex-wrap gap-1">
            <button className={flatButton} onClick={() => onRun(path)} title={busy ? "Add it to the queue" : "Run the script now"} type="button">
              <Play className="h-3 w-3" /> Run
            </button>
            {onSchedule && (
              <button className={flatButton} onClick={() => onSchedule(path)} title="Run it on set days and times" type="button">
                <CalendarClock className="h-3 w-3" /> Schedule
              </button>
            )}
            <button className={flatButton} onClick={() => onOpen(path)} title={`View the script (${path}); edit it in the project folder`} type="button">
              <FileCode2 className="h-3 w-3" /> View
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}
