import { FolderInput } from "lucide-react";
import { useState } from "react";
import type { IntakeGroup } from "@/lib/api";
import { cn } from "@/lib/utils";

const loadApi = () => import("@/lib/api").then((m) => m.api);

/**
 * The files a person put in a new project before its first request, by type, with what each type
 * can be used for (StreamHub's FileIntake table). One choice per type; StreamHub moves the app's
 * data into Source/, keeps the roles for every task, and sends what is to be done now to Copilot.
 */
export function IntakeCard({ groups, text, restored }: { groups: IntakeGroup[]; text: string; restored: boolean }) {
  const [choices, setChoices] = useState<Record<string, string>>(() => Object.fromEntries(groups.map((g) => [g.kind, g.default])));
  const [done, setDone] = useState("");
  const [busy, setBusy] = useState(false);
  if (restored) return null; // an earlier card: the project shows a new one while files are still open
  const apply = async () => {
    setBusy(true);
    try {
      const r = await (await loadApi()).intake(choices);
      setDone(
        `Saved.${r.moved.length ? ` ${r.moved.length} data file(s) moved into Source/.` : ""}${r.queued ? " Copilot is on it now." : " Copilot gets this with every task."}`,
      );
    } catch (e) {
      setDone((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="kit-panel space-y-3 text-sm">
      <div className="flex items-center gap-2 font-medium">
        <FolderInput className="h-4 w-4 text-muted-foreground" />
        {text}
      </div>
      {groups.map((g) => (
        <div className="space-y-1.5" key={g.kind}>
          <div className="text-muted-foreground text-xs">
            {g.label} ({g.count}): {g.files.slice(0, 4).join(", ")}
            {g.count > 4 ? ` and ${g.count - 4} more` : ""}
          </div>
          <div className="kit-segmented flex-wrap" role="group" aria-label={`What the ${g.label.toLowerCase()} are for`}>
            {g.options.map((o) => (
              <button
                aria-pressed={choices[g.kind] === o.value}
                className={cn("kit-btn kit-btn--sm", choices[g.kind] === o.value ? "" : "kit-btn--ghost")}
                disabled={busy || Boolean(done)}
                key={o.value}
                onClick={() => setChoices((c) => ({ ...c, [g.kind]: o.value }))}
                title={o.help}
                type="button"
              >
                {o.label}
              </button>
            ))}
          </div>
        </div>
      ))}
      {done ? (
        <div className="text-muted-foreground text-xs">{done}</div>
      ) : (
        <button className="kit-btn kit-btn--primary kit-btn--sm" disabled={busy} onClick={() => void apply()} type="button">
          Use these choices
        </button>
      )}
    </div>
  );
}
