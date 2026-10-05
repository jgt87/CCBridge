import { AlertTriangle, CircleAlert, EyeOff } from "lucide-react";
import { useState } from "react";
import { api, type CheckFinding } from "@/lib/api";

/**
 * The file check of one round: what breaks a file (errors) and likely mistakes (warnings), each
 * with Ignore for a false alarm. Ignore puts the finding on the project's ignore list (also used by
 * Code health > Issues) and in the false-alarm log; Copilot is not asked about it again.
 */
export function ChecksCard({ text, items }: { text: string; items: CheckFinding[] }) {
  const [ignored, setIgnored] = useState<Set<number>>(new Set());
  const [error, setError] = useState("");
  const ignore = async (i: number) => {
    const f = items[i];
    setError("");
    try {
      await api.ignoreCheck(f.path, f.text, f.source);
      setIgnored((s) => new Set(s).add(i));
    } catch (e) {
      setError((e as Error).message);
    }
  };
  return (
    <div className="rounded-xl border border-black/10 px-3 py-2 text-sm dark:border-white/10">
      <div className="mb-1 text-muted-foreground text-xs">{text}</div>
      <ul className="space-y-0.5">
        {items.map((f, i) => (
          <li className={ignored.has(i) ? "flex items-start gap-1.5 opacity-50" : "flex items-start gap-1.5"} key={`${f.path}-${i}`}>
            {f.level === "error" ? (
              <CircleAlert aria-label="breaks the file" className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            ) : (
              <AlertTriangle aria-label="likely mistake" className="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted-foreground" />
            )}
            <span className="min-w-0 flex-1 text-xs">
              {f.path && <span className="font-mono">{f.path}: </span>}
              {f.text}
            </span>
            {f.path && (
              <button
                className="inline-flex shrink-0 items-center gap-1 rounded px-1 text-muted-foreground text-xs hover:bg-black/5 hover:text-foreground disabled:opacity-40 dark:hover:bg-white/5"
                disabled={ignored.has(i)}
                onClick={() => ignore(i)}
                title="A false alarm for this code: never report it again (also hidden in Code health > Issues)"
                type="button"
              >
                <EyeOff className="h-3 w-3" /> {ignored.has(i) ? "Ignored" : "Ignore"}
              </button>
            )}
          </li>
        ))}
      </ul>
      {error && <div className="mt-1 text-rose-500 text-xs">{error}</div>}
    </div>
  );
}
