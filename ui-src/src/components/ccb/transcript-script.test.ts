import { describe, expect, it, vi } from "vitest";

// Rendering parts that need a browser are not used by buildTranscript.
vi.mock("./markdown-view", () => ({ MarkdownView: () => null }));
vi.mock("./action-card", () => ({ ActionCard: () => null }));
vi.mock("./undo-card", () => ({ UndoCard: () => null }));
vi.mock("./checks-card", () => ({ ChecksCard: () => null }));
vi.mock("@/components/kokonutui/ai-text-loading", () => ({ default: () => null }));
import type { AgentEvent } from "@/lib/api";
import { languageForPath } from "@/lib/highlight";
import { asPreview, buildTranscript } from "./transcript";

const ev = (seq: number, type: AgentEvent["type"], extra: Partial<AgentEvent> = {}): AgentEvent => ({ seq, type, time: "10:00:00", ...extra });

describe("script runs in the chat", () => {
  it("turns an older plain-text script preview (saved chat history) into a preview of the script", () => {
    const old = ev(1, "action", { id: "chain-1", action: "run", target: 'powershell -NoProfile -File "Scripts\\export.ps1"', status: "awaiting", preview: "Get-Date" as unknown as AgentEvent["preview"] });
    const items = buildTranscript([old]);
    const card = items.find((i) => i.kind === "action");
    expect(card?.kind === "action" && card.item.preview).toEqual({ path: "Scripts/export.ps1", exists: true, old: null, new: "Get-Date" });
  });
  it("keeps a proper preview and survives one without a path", () => {
    expect(asPreview({ path: "a.js", exists: true, old: "x", new: "y" })).toEqual({ path: "a.js", exists: true, old: "x", new: "y" });
    expect(asPreview(null)).toBeUndefined();
    expect(asPreview("text")?.path).toBe("");
    expect(languageForPath(undefined)).toBeNull();
  });
  it("shows a script's own finish line", () => {
    const items = buildTranscript([ev(1, "script", { text: "Script Scripts/export.ps1 finished: exit code 0." })]);
    expect(items.some((i) => i.kind === "note" && i.text.includes("finished: exit code 0"))).toBe(true);
  });
});
