import { describe, expect, it, vi } from "vitest";

// Rendering parts that need a browser are not used by buildTranscript.
vi.mock("./markdown-view", () => ({ MarkdownView: () => null }));
vi.mock("./action-card", () => ({ ActionCard: () => null }));
vi.mock("./undo-card", () => ({ UndoCard: () => null }));
vi.mock("./checks-card", () => ({ ChecksCard: () => null }));
vi.mock("@/components/kokonutui/ai-text-loading", () => ({ default: () => null }));
import { buildTranscript } from "./transcript";
import { editsRefusedText } from "./edits-refused-view";
import type { AgentEvent } from "@/lib/api";

describe("edits-refused card", () => {
  it("says how many edits to which files", () => {
    expect(editsRefusedText(1, ["app.js"])).toBe("Copilot wrote 1 edit to app.js, but StreamHub handled your message as a question, so nothing was changed.");
    expect(editsRefusedText(2, ["a.js", "b.css"])).toContain("2 edits to a.js, b.css");
  });
  it("becomes a card item with the replay id and the request", () => {
    const events = [{ seq: 1, type: "edits-refused", replayId: "abc", count: 2, files: "index.html", request: "Use a ring chart" }] as unknown as AgentEvent[];
    const [item] = buildTranscript(events);
    expect(item).toMatchObject({ kind: "editsRefused", replayId: "abc", count: 2, files: ["index.html"], request: "Use a ring chart", restored: false });
  });
});
