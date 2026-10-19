import { describe, expect, it, vi } from "vitest";

// Rendering parts that need a browser are not used by buildTranscript.
vi.mock("./markdown-view", () => ({ MarkdownView: () => null }));
vi.mock("./action-card", () => ({ ActionCard: () => null }));
vi.mock("./undo-card", () => ({ UndoCard: () => null }));
vi.mock("./checks-card", () => ({ ChecksCard: () => null }));
vi.mock("@/components/kokonutui/ai-text-loading", () => ({ default: () => null }));
import type { AgentEvent } from "@/lib/api";
import { buildTranscript } from "./transcript";

const ev = (seq: number, type: string, extra: Record<string, unknown>) => ({ seq, type, ...extra }) as unknown as AgentEvent;

describe("times in the transcript", () => {
  it("gives every item the time of its event, and an action when its result came in", () => {
    const items = buildTranscript([
      ev(1, "user", { text: "Build it", time: "12:00:00", at: "2026-10-19T12:00:00" }),
      ev(2, "action", { id: "a1", action: "run", target: "npm test", status: "running", time: "12:00:05", at: "2026-10-19T12:00:05" }),
      ev(3, "action-result", { id: "a1", ok: true, status: "done", time: "12:00:47", at: "2026-10-19T12:00:47" }),
      ev(4, "status", { text: "Checked.", time: "12:01:00", at: "2026-10-19T12:01:00" }),
    ]);
    expect(items.map((i) => i.at)).toEqual(["2026-10-19T12:00:00", "2026-10-19T12:00:05", "2026-10-19T12:01:00"]);
    expect(items[1].endAt).toBe("2026-10-19T12:00:47");
    expect(items[2].time).toBe("12:01:00");
  });
});
