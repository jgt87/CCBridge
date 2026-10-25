import type { ChangeBlock, Preview } from "@/lib/api";

/** The parts of an action card's item the view rules read (ActionItem in action-card.tsx). */
export interface ActionView {
  action: string;
  target: string;
  status: string;
  preview?: Preview | null;
  error?: string;
  output?: string;
  code?: string;
  reasons?: string[];
  summary?: string;
  decidedBy?: string;
  allowOptions?: string[];
}

/** The verb on the card's header line. */
export const VERBS: Record<string, string> = {
  runbook: "Run runbook",
  screenshot: "Screenshot",
  read: "Read",
  glob: "List",
  grep: "Search",
  write: "Write",
  edit: "Edit",
  run: "Run",
  todo: "Plan",
  move: "Move",
  restore: "Restore",
  delete: "Remove",
};

export const verbFor = (action: string): string => VERBS[action] ?? action;

const STATUS_CLASS: Record<string, string> = {
  running: "text-muted-foreground",
  awaiting: "font-medium text-foreground",
  ok: "text-muted-foreground",
  "already applied": "text-muted-foreground",
  failed: "text-(--kit-error)",
  rejected: "text-muted-foreground",
  skipped: "text-muted-foreground",
  interrupted: "text-muted-foreground",
  ambiguous: "text-muted-foreground",
};

const STATUS_LABEL: Record<string, string> = {
  interrupted: "interrupted (StreamHub restarted)",
  ambiguous: "needs a more exact SEARCH",
  running: "running",
  awaiting: "needs approval",
  ok: "done",
  "already applied": "already applied (verified)",
  failed: "failed",
  rejected: "rejected",
  skipped: "skipped (plan mode)",
};

export const statusClass = (status: string): string | undefined => STATUS_CLASS[status];
export const statusLabel = (status: string): string => STATUS_LABEL[status] ?? status;

/** A decision just sent shows as running until the next state arrives. */
export const shownStatus = (status: string, sent: boolean): string => (sent && status === "awaiting" ? "running" : status);

/** Whether the card has anything to open. */
export const hasDetails = (item: ActionView): boolean =>
  Boolean(item.preview || item.output || item.error || item.reasons?.length || item.action === "run");

/** Who decided, when it was not the person in this window: "MCP" or "API". */
export const decidedVia = (decidedBy?: string): string => (decidedBy && decidedBy !== "user" ? (decidedBy === "mcp" ? "MCP" : "API") : "");

/** A run that asked for a terminal: Open in a window gets the stronger look. */
export const needsTerminal = (item: ActionView): boolean =>
  /interactive terminal|needs a terminal|RUN-INTERACTIVE/i.test(`${item.output ?? ""} ${item.code ?? ""}`);

/** The result text below a finished step (a run has its console; a written to-do list its checklist). */
export const showsOutput = (item: ActionView, awaiting: boolean, isTodo: boolean): boolean =>
  Boolean(item.output) && !awaiting && item.action !== "run" && !(isTodo && item.status === "ok");

/** Open in a window: a run that is not waiting for approval, finished or asking a question or stuck. */
export const canOpenInWindow = (item: ActionView, awaiting: boolean, running: boolean, liveState?: string): boolean =>
  item.action === "run" && !awaiting && (!running || liveState === "question" || liveState === "stuck") && Boolean(item.target.trim());

/** Whether the live output now is this card's command: a run of this id that is running. */
export const ownsLive = (item: ActionView & { id: string }, liveId?: string): boolean =>
  item.action === "run" && item.status === "running" && liveId === item.id;

/** The web approval's choice of what to allow from now on. */
export const offersAllow = (item: ActionView, awaiting: boolean): boolean => awaiting && item.action === "web" && (item.allowOptions?.length ?? 0) > 0;

/** The done line: a summary that says more than the output. */
export const doneSummary = (item: ActionView): string =>
  (item.status === "ok" || item.status === "already applied") && item.summary && item.summary !== item.output ? item.summary : "";

/** The blocks of a change from the preview (one object or a list, as PowerShell sends them). */
export function asBlocks(h: Preview["hunks"]): ChangeBlock[] {
  if (!h) return [];
  return (Array.isArray(h) ? h : [h]).filter((b) => b && typeof b.index === "number");
}

/** Where a block is: "line 4-6 (+2 -3)" or "after line 9 (+1 -0)". */
export function blockPlace(b: ChangeBlock): string {
  const where = b.oldCount ? `line ${b.oldStart}${b.oldCount > 1 ? `-${b.oldStart + b.oldCount - 1}` : ""}` : `after line ${b.oldStart - 1}`;
  return `${where} (+${b.newCount} -${b.oldCount})`;
}

/** The approve button's words, by the kind of step (a web read is not a file). */
export function approveLabel(item: ActionView): string {
  switch (item.action) {
    case "web":
      return "Read";
    case "sql":
      return "Run query";
    case "remember":
      return "Save note";
    case "runbook":
      return "Run runbook";
    case "write":
    case "edit":
      return item.preview?.exists ? "Apply change" : "Create file";
    default:
      return "Approve";
  }
}

/** The card's red line: the reason only. Code and current lines stay in the output below it. */
export function shortError(text: string): string {
  const first = text.split(/\n|\s(?:Current lines|The closest place|What differs:)/)[0].trim();
  return first.length > 320 ? `${first.slice(0, 317)}...` : first;
}

/**
 * The short title of a run card: the program without its folder or .exe ("powershell", "npm"), plus
 * the script it runs when it runs a file (-File X.ps1, python X.py, node X.js). The whole command is
 * in the card's console.
 */
export function runTitle(command: string): string {
  const words = command.trim().match(/"[^"]*"|'[^']*'|\S+/g) ?? [];
  if (!words.length) return "";
  const bare = (w: string) => w.replace(/^["']|["']$/g, "");
  const program = (bare(words[0] ?? "").split(/[\\/]/).pop() ?? "").replace(/\.(exe|cmd|bat)$/i, "");
  const script = (() => {
    const at = words.findIndex((w) => /^-file$/i.test(w));
    if (at > 0 && words[at + 1]) return bare(words[at + 1]);
    const first = words.slice(1).find((w) => !w.startsWith("-"));
    return first && /\.(ps1|py|js|mjs|cjs|ts|bat|cmd|sh)$/i.test(bare(first)) ? bare(first) : "";
  })();
  return script ? `${program} ${script}` : program;
}
