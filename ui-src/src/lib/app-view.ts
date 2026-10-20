import type { AgentChoice } from "@/components/ccb/app-chrome";
import type { ChatOptions } from "@/lib/api";
import type { RunWindowState } from "@/lib/run-live";

// Remembered in this browser: Clarify first, and who answers the next message (Auto, the default,
// lets StreamHub pick by fixed words: Researcher, Analyst or Copilot itself).
export const parseClarify = (raw: string | null) => raw === "1";
export const showClarify = (on: boolean) => (on ? "1" : "0");
export const parseAgent = (raw: string | null): AgentChoice => (raw === "researcher" || raw === "analyst" || raw === "copilot" ? raw : "auto");
export const showAgent = (v: AgentChoice) => v;

/** What goes with a message: the agent, and Clarify first (an agent itself is never clarified first). */
export function sendOptions(agent: AgentChoice, clarify: boolean): ChatOptions {
  if (agent === "copilot") return { clarify };
  if (agent === "auto") return { agent, clarify };
  return { agent };
}

const IMAGE = /\.(png|jpe?g|gif|webp|svg|bmp)$/i;

/** Images are shown from the project's read-only preview address, not read as text. */
export const isImagePath = (path: string) => IMAGE.test(path);

/** The server sends one console window as an object and several as a list. */
export function runWindowList(w: RunWindowState[] | RunWindowState | undefined): RunWindowState[] {
  if (Array.isArray(w)) return w;
  return w ? [w] : [];
}

/** The draft with an @path added, separated by one space. */
export const withAttached = (draft: string, path: string) => `${draft}${draft && !draft.endsWith(" ") ? " " : ""}@${path} `;
