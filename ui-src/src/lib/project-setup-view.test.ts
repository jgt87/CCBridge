import { describe, expect, it } from "vitest";
import type { SetupChoice } from "./api";
import { answerLabel, holdsRequest, initialAnswers, isChosen, setupReply, toggleAnswer } from "./project-setup-view";

const opt = (value: string, label: string) => ({ value, label, help: "" });
const single: SetupChoice = { id: "language", question: "Which language?", options: [opt("nl", "Dutch"), opt("en", "English")] };
const multi: SetupChoice = { id: "extras", question: "Extras?", options: [opt("export", "Export"), opt("print", "Print")], multi: true };
const lone: SetupChoice = { id: "persist", question: "Keep data?", options: opt("none", "No") };
const forms = [opt("single", "One file"), opt("modular", "Separate files")];

describe("project setup card", () => {
  it("starts on each question's first choice, a multi-select empty, a lone option as a list", () => {
    expect(initialAnswers([single, multi, lone])).toEqual({ language: "nl", extras: "", persist: "none" });
  });

  it("takes one choice, or adds and removes a multi-select's choices", () => {
    expect(toggleAnswer(single, "nl", "en")).toBe("en");
    expect(toggleAnswer(multi, "", "export")).toBe("export");
    expect(toggleAnswer(multi, "export", "print")).toBe("export,print");
    expect(toggleAnswer(multi, "export,print", "export")).toBe("print");
    expect(isChosen(multi, "export,print", "print")).toBe(true);
    expect(isChosen(single, "en", "nl")).toBe(false);
  });

  it("writes an answer as its labels, or none", () => {
    expect(answerLabel(multi, "export,print")).toBe("Export, Print");
    expect(answerLabel(multi, "")).toBe("none");
    expect(answerLabel(single, "xx")).toBe("xx");
  });

  it("sends the build form, the live file and the answers, with the plan and clarify choices", () => {
    const r = setupReply({ request: "Build a page", clarify: false, buildOptions: forms, build: "modular", live: true, path: "  C:\\d.csv ", others: [single], answers: { language: "en", bigtask: "plan" } });
    expect(r.note).toBe("Build form: Separate files; live data from C:\\d.csv; Which language: English. Sent to Copilot.");
    expect(r.opts).toEqual({ setup: { build: "modular", liveSource: "C:\\d.csv", answers: { language: "en", bigtask: "plan" } }, planFirst: true, request: "Build a page" });
    const c = setupReply({ request: "x", clarify: true, buildOptions: null, build: "single", live: false, path: "", others: [], answers: {} });
    expect(c.opts).toEqual({ setup: { answers: {} }, clarify: true });
    expect(setupReply({ request: "x", clarify: false, buildOptions: forms, build: "single", live: true, path: " ", others: [], answers: {} }).opts?.setup).toEqual({ build: "single", liveSource: undefined, answers: {} });
  });

  it("sends nothing for an answer that means not now, and says what to do", () => {
    expect(holdsRequest({ addto: "project" })).toBe(true);
    expect(holdsRequest({ sampledata: "wait" })).toBe(true);
    expect(holdsRequest({ addto: "existing" })).toBe(false);
    const p = setupReply({ request: "x", clarify: false, buildOptions: null, build: "single", live: false, path: "", others: [], answers: { addto: "project" } });
    expect(p.opts).toBeNull();
    expect(p.note).toContain("Create the new project in the project list");
    expect(setupReply({ request: "x", clarify: false, buildOptions: null, build: "single", live: false, path: "", others: [], answers: { sampledata: "wait" } }).note).toContain("Add the data file to the project");
  });
});
