import { describe, expect, it } from "vitest";
import { buildPlanMessage, changePlanMessage, clarifyMessage } from "./plan-messages";

const questions = [
  { question: "Which colour?", options: ["Blue", "Grey"] },
  { question: "Mobile too?", options: [] },
];

describe("clarify answers", () => {
  it("sends the answers with the request, no preference for an empty one", () => {
    expect(clarifyMessage({ request: "Make a page", questions, answers: [" Grey ", ""], planId: "p1", withAnswers: true })).toEqual({
      text: "Make a page\n\nMy answers to your questions:\n1. Which colour?\n   Answer: Grey\n2. Mobile too?\n   Answer: (no preference)",
      opts: {
        planFirst: true,
        request: "Make a page",
        planId: "p1",
        answers: [
          { question: "Which colour?", answer: "Grey" },
          { question: "Mobile too?", answer: "" },
        ],
      },
    });
  });

  it("sends the request alone when the questions are skipped", () => {
    expect(clarifyMessage({ request: "Make a page", questions, answers: ["Blue", ""], withAnswers: false })).toEqual({
      text: "Make a page",
      opts: { planFirst: true, request: "Make a page", planId: undefined, skipped: true },
    });
  });
});

describe("plan messages", () => {
  it("builds an approved plan or continues an unfinished one", () => {
    expect(buildPlanMessage("plan", "R", "P")).toBe("Build this now, following the approved plan below. Change files with action blocks.\n\nRequest: R\n\nApproved plan:\nP");
    expect(buildPlanMessage("proposal", "R", "P")).toBe(buildPlanMessage("plan", "R", "P"));
    expect(buildPlanMessage("unfinished", "R", "P")).toBe(
      "Continue and make the change now: read what you still need, then change the files with action blocks in this task. Do not stop before the change is made.\n\nRequest: R\n\nWhat you said you would do:\nP",
    );
  });

  it("asks for a change to the plan", () => {
    expect(changePlanMessage(" Fewer steps ", "R", "P")).toBe("Change the plan: Fewer steps\n\nRequest: R\n\nCurrent plan:\nP");
  });
});
