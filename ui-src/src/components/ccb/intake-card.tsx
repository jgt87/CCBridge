import { FolderInput } from "lucide-react";
import { useState } from "react";
import type { IntakeGroup } from "@/lib/api";
import { intakeFilesLine, intakeSavedText } from "@/lib/intake-card";
import { cn } from "@/lib/utils";

const loadApi = () => import("@/lib/api").then((m) => m.api);

/** One type of file: its files, and one button per use (the chosen one filled). */
function IntakeGroupChoice({
  group: g,
  chosen,
  disabled,
  onChoose,
}: {
  group: IntakeGroup;
  chosen: string | undefined;
  disabled: boolean;
  onChoose: (value: string) => void;
}) {
  return (
    <div className="space-y-1.5">
      <div className="text-muted-foreground text-xs">{intakeFilesLine(g)}</div>
      <div className="kit-segmented flex-wrap" role="group" aria-label={`What the ${g.label.toLowerCase()} are for`}>
        {g.options.map((o) => (
          <button
            aria-pressed={chosen === o.value}
            className={cn("kit-btn kit-btn--sm", chosen === o.value ? "" : "kit-btn--ghost")}
            disabled={disabled}
            key={o.value}
            onClick={() => onChoose(o.value)}
            title={o.help}
            type="button"
          >
            {o.label}
          </button>
        ))}
      </div>
    </div>
  );
}

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
      setDone(intakeSavedText(await (await loadApi()).intake(choices)));
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
        <IntakeGroupChoice
          chosen={choices[g.kind]}
          disabled={busy || Boolean(done)}
          group={g}
          key={g.kind}
          onChoose={(value) => setChoices((c) => ({ ...c, [g.kind]: value }))}
        />
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
