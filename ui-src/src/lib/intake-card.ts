// Texts of the files-intake card (components/ccb/intake-card.tsx).
import type { IntakeGroup } from "@/lib/api";

/** The files of one type: the first four by name, then how many more. */
export function intakeFilesLine(g: Pick<IntakeGroup, "label" | "count" | "files">): string {
  return `${g.label} (${g.count}): ${g.files.slice(0, 4).join(", ")}${g.count > 4 ? ` and ${g.count - 4} more` : ""}`;
}

/** What the card says once the choices are saved. */
export function intakeSavedText(r: { moved: string[]; queued: string | null }): string {
  const moved = r.moved.length ? ` ${r.moved.length} data file(s) moved into Source/.` : "";
  return `Saved.${moved}${r.queued ? " Copilot is on it now." : " Copilot gets this with every task."}`;
}
