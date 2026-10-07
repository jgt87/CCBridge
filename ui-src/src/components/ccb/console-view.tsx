import { cn } from "@/lib/utils";

/**
 * A command's output drawn like a Windows console window: black, Consolas, light grey text.
 * `title` is the bar at the top (the command), `footer` a status line under the output.
 */
export function ConsoleView({
  title,
  lines,
  footer,
  live = false,
  className,
}: {
  title?: string;
  lines: string[];
  footer?: React.ReactNode;
  /** Running now: a blinking cursor after the last line. */
  live?: boolean;
  className?: string;
}) {
  return (
    <div className={cn("overflow-hidden rounded-md border border-neutral-700 bg-[#0c0c0c] text-[#cccccc]", className)}>
      {title && (
        <div className="truncate border-neutral-800 border-b bg-[#1f1f1f] px-3 py-1 font-[Consolas,'Cascadia_Mono','Courier_New',monospace] text-[11px] text-neutral-400">
          {title}
        </div>
      )}
      <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words px-3 py-2 font-[Consolas,'Cascadia_Mono','Courier_New',monospace] text-[12.5px] leading-[1.35]">
        {lines.length ? lines.join("\n") : live ? "" : "(no output)"}
        {live && <span className="ml-px inline-block h-[1.05em] w-[0.55em] translate-y-[2px] animate-pulse bg-[#cccccc] align-text-bottom" />}
      </pre>
      {footer && <div className="border-neutral-800 border-t px-3 py-1 font-[Consolas,'Cascadia_Mono','Courier_New',monospace] text-[11px] text-neutral-400">{footer}</div>}
    </div>
  );
}
