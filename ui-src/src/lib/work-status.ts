import type { WorkStatus } from "@/lib/api";
import { formatDuration } from "@/lib/row-time";

/** No sign of life for this long: the waiting card warns, and a notification goes out once. */
export const QUIET_WARN_MS = 3 * 60_000;

const ms = (iso: string | undefined, now: number) => {
  if (!iso) return null;
  const t = new Date(iso).getTime();
  return Number.isNaN(t) ? null : Math.max(0, now - t);
};

export interface WorkView {
  /** What StreamHub is doing now, with how long: "Waiting for Copilot's reply - 2 min 10 s". */
  phase: string;
  /** The task as a whole: "Task 6 min 40 s - round 3 - 4 actions - 2 files changed". */
  detail: string;
  /** When something last happened in this step: "Copilot wrote 5 s ago", else "updated 5 s ago"; "" when nothing did since it began. */
  sign: string;
  /** How long nothing new happened. */
  quietMs: number;
  /** Quiet for QUIET_WARN_MS or longer. */
  quiet: boolean;
  /** What StreamHub does about it, for the warning. */
  quietText: string;
  steps: { at: string; text: string }[];
}

/** The status lines of the waiting card from the server's work status, at time `now`. */
export function workView(w: WorkStatus, now: number = Date.now()): WorkView {
  const phaseFor = ms(w.phaseAt, now);
  const total = ms(w.startedAt, now);
  const quietMs = ms(w.lastSignAt, now) ?? 0;
  const data = ms(w.lastDataAt, now);
  const parts = [total != null ? `Task ${formatDuration(total)}` : ""];
  if (w.round > 1) parts.push(`round ${w.round}`);
  if (w.actions) parts.push(`${w.actions} action${w.actions === 1 ? "" : "s"}`);
  if (w.changed) parts.push(`${w.changed} file${w.changed === 1 ? "" : "s"} changed`);
  // Said only when something happened after this step began: otherwise it repeats the step's own time.
  const newSinceStep = phaseFor == null || quietMs < phaseFor - 2000;
  const sign = !newSinceStep ? "" : data != null && data <= quietMs + 1000 ? `Copilot wrote ${formatDuration(data)} ago` : `updated ${formatDuration(quietMs)} ago`;
  const quietText = w.waitSec
    ? `StreamHub keeps waiting while Copilot's page shows it is at work, up to ${formatDuration(w.waitSec * 1000)} in all; with no sign at all it stops after ${formatDuration(w.stallSec * 1000)}.`
    : "StreamHub is still on this step; it ends by itself when the step finishes or times out.";
  const steps = (Array.isArray(w.steps) ? w.steps : w.steps ? [w.steps] : []).filter((s) => s?.text);
  return {
    phase: phaseFor != null ? `${w.phase} · ${formatDuration(phaseFor)}` : w.phase,
    detail: parts.filter(Boolean).join(" · "),
    sign,
    quietMs,
    quiet: quietMs >= QUIET_WARN_MS,
    quietText,
    steps,
  };
}

/** The browser tab's title: what StreamHub is doing and for how long, so it shows from another tab. */
export function tabTitle(busy: boolean, w: WorkStatus | null | undefined, now: number = Date.now()): string {
  if (!busy || !w) return "StreamHub";
  const total = ms(w.startedAt, now);
  const quiet = (ms(w.lastSignAt, now) ?? 0) >= QUIET_WARN_MS;
  const phase = w.phase.length > 40 ? `${w.phase.slice(0, 39)}…` : w.phase;
  // Minutes only: the title changes once a minute, not every second.
  const mins = total != null ? `${Math.floor(total / 60_000)} min` : "";
  return `${quiet ? "⚠" : "⏳"} ${phase}${mins ? ` · ${mins}` : ""} – StreamHub`;
}

/** A quiet spell worth one desktop notification: busy, quiet long enough, and not this spell again
 *  (`noticed` is the last sign of life already notified about). */
export function isNewQuietSpell(busy: boolean, w: WorkStatus | null | undefined, noticed: string, now: number = Date.now()): w is WorkStatus {
  if (!busy || !w) return false;
  return workView(w, now).quiet && noticed !== w.lastSignAt;
}
