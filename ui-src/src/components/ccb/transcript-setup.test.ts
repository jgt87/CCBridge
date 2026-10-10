import { describe, expect, it, vi } from "vitest";

// Rendering parts that need a browser are not used by buildTranscript.
vi.mock("./markdown-view", () => ({ MarkdownView: () => null }));
vi.mock("./action-card", () => ({ ActionCard: () => null }));
vi.mock("./undo-card", () => ({ UndoCard: () => null }));
vi.mock("./checks-card", () => ({ ChecksCard: () => null }));
vi.mock("@/components/kokonutui/ai-text-loading", () => ({ default: () => null }));
import type { AgentEvent } from "@/lib/api";
import { BUILD_FORMS } from "@/lib/build-forms";
import { buildTranscript } from "./transcript";

const ev = (seq: number, type: AgentEvent["type"], extra: Partial<AgentEvent> = {}): AgentEvent => ({ seq, type, time: "10:00:00", ...extra });
const question = { id: "build", question: "How should this be built?", options: BUILD_FORMS };

describe("the project setup card", () => {
  it("shows the questions with the request, live data and Clarify first kept for the answer", () => {
    const items = buildTranscript([
      ev(1, "user", { text: "Build a dashboard from sales.csv" }),
      ev(2, "setup-choice", { request: "Build a dashboard from sales.csv", choices: [question], live: true, suggest: "C:\\Data\\sales.csv", clarify: true }),
    ]);
    const card = items.find((i) => i.kind === "setupChoice");
    expect(card).toMatchObject({ kind: "setupChoice", request: "Build a dashboard from sales.csv", live: true, suggest: "C:\\Data\\sales.csv", clarify: true, restored: false });
    expect(card?.kind === "setupChoice" && card.choices[0].id).toBe("build");
  });
  it("takes a single question (one JSON object) as a list, and marks a restored card", () => {
    const items = buildTranscript([ev(1, "setup-choice", { request: "Make a report", choices: question, restored: true })]);
    const card = items.find((i) => i.kind === "setupChoice");
    expect(card?.kind === "setupChoice" && card.choices.length).toBe(1);
    expect(card?.kind === "setupChoice" && card.restored).toBe(true);
    expect(card?.kind === "setupChoice" && card.live).toBe(false);
  });
  it("keeps every question of a card, the build one and the registry ones with their scope and multi flag", () => {
    const more = [
      { id: "appkind", question: "What kind of app is this?", options: [{ value: "web", label: "Web pages", help: "" }], scope: "project" },
      { id: "extras", question: "Extras for tables and reports?", options: [{ value: "export", label: "Export", help: "" }], multi: true, scope: "project" },
      { id: "recurring", question: "This sounds like recurring work.", options: [{ value: "runbook", label: "Make it a runbook", help: "" }], scope: "request" },
    ];
    const items = buildTranscript([ev(1, "setup-choice", { request: "Build an app", choices: [question, ...more] })]);
    const card = items.find((i) => i.kind === "setupChoice");
    expect(card?.kind === "setupChoice" && card.choices.map((c) => c.id)).toEqual(["build", "appkind", "extras", "recurring"]);
    expect(card?.kind === "setupChoice" && card.choices[2].multi).toBe(true);
    expect(card?.kind === "setupChoice" && card.choices[3].scope).toBe("request");
  });
  it("offers the same three forms in the card and in the Project setup section", () => {
    expect(BUILD_FORMS.map((f) => f.value)).toEqual(["single", "modular", "copilot"]);
  });
});
