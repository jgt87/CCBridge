import { describe, expect, it, vi } from "vitest";

// Rendering parts that need a browser are not used by buildTranscript.
vi.mock("./markdown-view", () => ({ MarkdownView: () => null }));
vi.mock("./action-card", () => ({ ActionCard: () => null }));
vi.mock("./undo-card", () => ({ UndoCard: () => null }));
vi.mock("@/components/kokonutui/ai-text-loading", () => ({ default: () => null }));
import type { AgentEvent } from "@/lib/api";
import { buildTranscript } from "./transcript";

const ev = (seq: number, type: AgentEvent["type"], extra: Partial<AgentEvent> = {}): AgentEvent => ({ seq, type, time: "10:00:00", ...extra });

describe("agent messages in the transcript", () => {
  it("keeps who a message went to, who answered, and the plan card", () => {
    const items = buildTranscript([
      ev(1, "user", { text: "Compare three generators", agent: "Researcher" }),
      ev(2, "assistant", { text: "My plan. Which period?", agent: "Researcher" }),
      ev(3, "agent-plan", { agent: "Researcher" }),
    ]);
    expect(items[0]).toMatchObject({ kind: "user", agent: "Researcher" });
    expect(items[1]).toMatchObject({ kind: "assistant", agent: "Researcher" });
    expect(items[2]).toMatchObject({ kind: "agentPlan", agent: "Researcher" });
  });
  it("leaves normal messages without an agent", () => {
    const items = buildTranscript([ev(1, "user", { text: "hi" }), ev(2, "assistant", { text: "hello" })]);
    expect("agent" in items[0]).toBe(false);
    expect("agent" in items[1]).toBe(false);
  });
});
