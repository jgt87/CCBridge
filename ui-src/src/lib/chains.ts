import type { ChainItem, ChainStep } from "@/lib/api";

/** What a chain's add-step form sends: the step's kind, target and arguments. */
export interface StepToAdd {
  kind: "runbook" | "script" | "download";
  target: string;
  args: string;
}

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

/** A download link's file name: the last part of its path, without the query. */
function downloadFile(target: string): string {
  return decodeURIComponent(target.split("?")[0].split("/").pop() || target);
}

/** What follows a step's target: a script's arguments, or the files a runbook step gets. */
function stepExtra(s: ChainStep): string {
  if (s.kind === "script" && s.args) return ` ${s.args}`;
  if (s.kind === "runbook" && s.with?.length) return ` + ${plural(s.with.length, "file")}`;
  return "";
}

/** One step as a short line: "runbook meetings", "script Scripts/x.ps1 -Week 1", "runbook summary + 1 file", "download sales.csv to Downloads/sales.csv". */
export function stepText(s: ChainStep): string {
  if (s.kind === "download") return `download ${downloadFile(s.target)} to ${s.args || "Downloads/"}`;
  return `${s.kind} ${s.target}${stepExtra(s)}`;
}

/** "1 step", "3 steps". */
export const stepCount = (n: number) => plural(n, "step");

/** The Run button's tooltip: why it cannot run, or what clicking does. */
export function runTitle(c: ChainItem, busy: boolean): string {
  if (c.steps.length === 0) return "Add a step first";
  if (c.problems.length) return "Fix the steps first";
  return busy ? "Add it to the queue" : "Run the steps now, one after another";
}

/** The step the add form describes; `pick` is "runbook:NAME", "script:PATH" or "download:". */
export function stepToAdd(pick: string, args: string, link: string): StepToAdd {
  if (pick === "download:") return { kind: "download", target: link.trim(), args: args.trim() };
  const isScript = pick.startsWith("script:");
  return { kind: isScript ? "script" : "runbook", target: pick.slice(pick.indexOf(":") + 1), args: isScript ? args : "" };
}

/** The Add button is usable: something picked, not saving, and a download has its link. */
export function canAddStep(pick: string, link: string, saving: boolean): boolean {
  return !!pick && !saving && !(pick === "download:" && !link.trim());
}
