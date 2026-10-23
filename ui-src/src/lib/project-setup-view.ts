import type { BuildForm, ChatOptions, SetupChoice } from "@/lib/api";

// The rules of the project setup card (components/ccb/project-setup.tsx): starting answers, multi
// choices, the answer as text, and what an answer sends.

export type SetupOption = { value: string; label: string; help: string };

export const asList = <T,>(v: T[] | T | undefined): T[] => (Array.isArray(v) ? v : v ? [v] : []);

/** The first choice of every question is the usual one; a multi-select starts empty. */
export function initialAnswers(questions: SetupChoice[]): Record<string, string> {
  return Object.fromEntries(questions.map((q) => [q.id, q.multi ? "" : (asList(q.options)[0]?.value ?? "")]));
}

const picked = (value: string) => value.split(",").filter(Boolean);

/** Whether an option is chosen: one value, or one of a multi-select's comma-separated values. */
export function isChosen(q: SetupChoice, value: string, option: string): boolean {
  return q.multi ? picked(value).includes(option) : value === option;
}

/** A click on an option: a single choice takes it, a multi-select adds or removes it. */
export function toggleAnswer(q: SetupChoice, value: string, option: string): string {
  if (!q.multi) return option;
  const set = new Set(picked(value));
  if (set.has(option)) set.delete(option);
  else set.add(option);
  return [...set].join(",");
}

/** An answer as the card writes it back: the options' labels, "none" when nothing is chosen. */
export function answerLabel(q: SetupChoice, value: string): string {
  return picked(value).map((x) => asList(q.options).find((o) => o.value === x)?.label ?? x).join(", ") || "none";
}

/** Answers that mean "not now": nothing goes to Copilot, the note says what to do. */
export function holdsRequest(answers: Record<string, string>): boolean {
  return answers.addto === "project" || answers.sampledata === "wait";
}

export interface SetupInput {
  request: string;
  clarify: boolean;
  /** The build question was asked, with these options. */
  buildOptions: SetupOption[] | null;
  build: BuildForm;
  live: boolean;
  path: string;
  others: SetupChoice[];
  answers: Record<string, string>;
}

/** What the card says after the answer, and the chat options to send (null: nothing is sent). */
export function setupReply(s: SetupInput): { note: string; opts: ChatOptions | null } {
  const parts: string[] = [];
  const livePath = s.path.trim();
  if (s.buildOptions) {
    const label = s.buildOptions.find((o) => o.value === s.build)?.label ?? s.build;
    parts.push(`Build form: ${label}${s.live && livePath ? `; live data from ${livePath}` : ""}`);
  }
  for (const q of s.others) parts.push(`${q.question.replace(/\?$/, "")}: ${answerLabel(q, s.answers[q.id] || "")}`);
  const said = parts.join("; ");
  if (s.answers.addto === "project") return { note: `${said}. Create the new project in the project list, open it, and send the request there.`, opts: null };
  if (s.answers.sampledata === "wait") return { note: `${said}. Add the data file to the project (Source/ or the project folder), then send the request again.`, opts: null };
  const opts: ChatOptions = { setup: { ...(s.buildOptions ? { build: s.build, liveSource: s.live ? livePath || undefined : undefined } : {}), answers: s.answers } };
  if (s.clarify || s.answers.bigtask === "clarify") opts.clarify = true;
  if (s.answers.bigtask === "plan") {
    opts.planFirst = true;
    opts.request = s.request;
  }
  return { note: `${said}. Sent to Copilot.`, opts };
}
