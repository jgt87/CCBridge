import type { ChatOptions } from "./api";

/** Which plan card: a plan-first plan, a proposal Copilot made, or a reply that stopped before the change. */
export type PlanVariant = "plan" | "proposal" | "unfinished";

/** The answers to Copilot's questions, or the request alone when they are skipped, sent to plan first. */
export function clarifyMessage({
  request,
  questions,
  answers,
  planId,
  withAnswers,
}: {
  request: string;
  questions: { question: string }[];
  answers: string[];
  planId?: string;
  withAnswers: boolean;
}): { text: string; opts: ChatOptions } {
  const lines = questions.map((q, i) => `${i + 1}. ${q.question}\n   Answer: ${answers[i].trim() || "(no preference)"}`).join("\n");
  return {
    text: withAnswers ? `${request}\n\nMy answers to your questions:\n${lines}` : request,
    opts: {
      planFirst: true,
      request,
      planId,
      ...(withAnswers ? { answers: questions.map((q, i) => ({ question: q.question, answer: answers[i].trim() })) } : { skipped: true }),
    },
  };
}

/** The message that builds an approved plan, or continues a reply that stopped before the change. */
export function buildPlanMessage(variant: PlanVariant, request: string, plan: string): string {
  return variant === "unfinished"
    ? `Continue and make the change now: read what you still need, then change the files with action blocks in this task. Do not stop before the change is made.\n\nRequest: ${request}\n\nWhat you said you would do:\n${plan}`
    : `Build this now, following the approved plan below. Change files with action blocks.\n\nRequest: ${request}\n\nApproved plan:\n${plan}`;
}

/** The message that asks Copilot to change its plan. */
export function changePlanMessage(feedback: string, request: string, plan: string): string {
  return `Change the plan: ${feedback.trim()}\n\nRequest: ${request}\n\nCurrent plan:\n${plan}`;
}
