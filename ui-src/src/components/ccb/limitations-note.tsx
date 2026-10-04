import { Info } from "lucide-react";
import { LIMITATIONS } from "@/lib/limitations";

/** The start screen's short list of what StreamHub does not do (yet). */
export function LimitationsNote() {
  return (
    <div className="w-full max-w-md rounded-lg border border-black/10 px-4 py-3 text-left dark:border-white/10">
      <div className="mb-2 flex items-center gap-1.5 font-medium text-muted-foreground text-xs uppercase tracking-wide">
        <Info aria-hidden className="h-3.5 w-3.5" /> Limitations
      </div>
      <ul className="space-y-1.5">
        {LIMITATIONS.map((l) => (
          <li className="text-sm" key={l.title}>
            <span className="font-medium">{l.title}</span>
            <span className="text-muted-foreground"> — {l.detail}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
