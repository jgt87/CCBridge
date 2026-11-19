import { cn } from "@/lib/utils";

/** A label whose button turns bold when selected (segmented choices, the Settings sections): a
 *  hidden bold copy (index.css .ccb-bold-label) reserves the bold width, so selecting one never
 *  moves its neighbours. */
export function BoldLabel({ text }: { text: string }) {
  return (
    <span className="ccb-bold-label" data-label={text}>
      <span>{text}</span>
    </span>
  );
}

/** A file name or path cut in the middle: the stem shrinks with an ellipsis and the extension keeps
 *  its width, so a long name still shows what kind of file it is. The caller puts the full name in
 *  a title. A name without an extension (or a dot file such as .gitignore) truncates at the end. */
export function FileName({ name, className }: { name: string; className?: string }) {
  const dot = name.lastIndexOf(".");
  if (dot <= name.lastIndexOf("/") + 1 || dot === name.length - 1) return <span className={cn("min-w-0 truncate", className)}>{name}</span>;
  return (
    <span className={cn("flex min-w-0", className)}>
      <span className="truncate">{name.slice(0, dot)}</span>
      <span className="shrink-0">{name.slice(dot)}</span>
    </span>
  );
}
