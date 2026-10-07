import { createContext, useContext } from "react";

/** The command StreamHub runs now (server New-RunWatch): its last output lines, sent with the app state. */
export interface RunLive {
  id: string;
  label: string;
  command: string;
  elapsed: number;
  lines: string[];
  quietSec: number;
  /** running | quiet (no output, still working) | stuck (no output, no CPU) | question (asks something). */
  state: string;
}

/** A command the person opened in a console window, still running. */
export interface RunWindowState {
  id: string;
  elapsed: number;
}

export interface RunLiveView {
  live: RunLive | null;
  windows: RunWindowState[];
}

export const RunLiveContext = createContext<RunLiveView>({ live: null, windows: [] });
export const useRunLive = () => useContext(RunLiveContext);

/** 0:07, 1:42, 1:02:03. */
export function formatElapsed(sec: number): string {
  const s = Math.max(0, Math.floor(sec || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${r}` : `${m}:${r}`;
}

/** What a running command looks like, in words, or "" while it simply runs. */
export function waitText(live: Pick<RunLive, "state" | "quietSec">): string {
  const quiet = formatElapsed(live.quietSec);
  switch (live.state) {
    case "question":
      return "It seems to ask a question. Commands here run without a terminal, so nobody can answer it: stop it and use Open in a window.";
    case "stuck":
      return `No output for ${quiet} and no CPU use: it seems to wait for something. Stop it, or open it in a window to see more.`;
    case "quiet":
      return `No output for ${quiet}, but it is still working.`;
    default:
      return "";
  }
}

/** Lines to show: a list from the server (an array, or one string from PowerShell's JSON). */
export function liveLines(lines: unknown): string[] {
  if (Array.isArray(lines)) return lines.map((l) => String(l ?? ""));
  if (typeof lines === "string" && lines) return lines.split("\n");
  return [];
}

/**
 * A finished run's output as the server writes it ("exit code 0", then the output between ~~~~
 * lines, then notes): the status, the console lines and the notes. Other text is all console.
 */
export function parseRunOutput(output: string): { status: string; lines: string[]; notes: string } {
  const m = /^([^\n]*)\n~~~~\n([\s\S]*?)\n?~~~~(?:\n([\s\S]*))?$/.exec(output ?? "");
  if (!m) return { status: "", lines: (output ?? "").replace(/\s+$/, "").split("\n"), notes: "" };
  const body = m[2].replace(/\s+$/, "");
  return { status: m[1].trim(), lines: body ? body.split("\n") : [], notes: (m[3] ?? "").trim() };
}
