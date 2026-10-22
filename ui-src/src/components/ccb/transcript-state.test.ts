import { describe, expect, it, vi } from "vitest";

// Rendering parts that need a browser are not used by these helpers.
vi.mock("./markdown-view", () => ({ MarkdownView: () => null }));
vi.mock("./action-card", () => ({ ActionCard: () => null }));
vi.mock("./undo-card", () => ({ UndoCard: () => null }));
vi.mock("./checks-card", () => ({ ChecksCard: () => null }));
vi.mock("@/components/kokonutui/ai-text-loading", () => ({ default: () => null }));
import type { Activity } from "@/lib/api";
import type { RunLive } from "@/lib/run-live";
import { indicatorTexts, type TranscriptItem, transcriptState } from "./transcript";

const note = { kind: "note", tone: "info", text: "New chat", seq: 1 } as unknown as TranscriptItem;
const user = { kind: "user", text: "Build it", seq: 2 } as unknown as TranscriptItem;
const action = (id: string, status: string) => ({ kind: "action", seq: 3, item: { id, status } }) as unknown as TranscriptItem;
const activity = (label: string) => ({ label, kind: "index" }) as unknown as Activity;
const run = (id: string) => ({ id }) as unknown as RunLive;

describe("transcriptState", () => {
  it("shows the welcome view for a fresh chat with only info notes", () => {
    expect(transcriptState([note], false, null, null).showEmpty).toBe(true);
    expect(transcriptState([note, user], false, null, null).showEmpty).toBe(false);
    expect(transcriptState([note], true, null, null).showEmpty).toBe(false);
    expect(transcriptState([note], false, activity("Indexing"), null).showEmpty).toBe(false);
  });

  it("shows the waiting card while busy or working, unless a step awaits approval", () => {
    expect(transcriptState([user], true, null, null).waiting).toBe(true);
    expect(transcriptState([user], false, activity("Indexing"), null).waiting).toBe(true);
    expect(transcriptState([user], false, null, null).waiting).toBe(false);
    const awaiting = transcriptState([user, action("a1", "awaiting")], true, null, null);
    expect(awaiting.awaiting).toBe(true);
    expect(awaiting.waiting).toBe(false);
  });

  it("gives a running command a console only when it has no card", () => {
    expect(transcriptState([user], true, null, run("r1")).liveWithoutCard).toEqual({ id: "r1" });
    expect(transcriptState([user, action("r1", "running")], true, null, run("r1")).liveWithoutCard).toBeNull();
    expect(transcriptState([user], true, null, null).liveWithoutCard).toBeNull();
  });
});

describe("indicatorTexts", () => {
  it("says Stopping first, then StreamHub's own work", () => {
    expect(indicatorTexts({ progress: "", stopping: true, activity: activity("Indexing"), seed: 1, look: false })).toEqual(["Stopping..."]);
    expect(indicatorTexts({ progress: "", stopping: false, activity: activity("Indexing"), seed: 1, look: false })[0]).toContain("Indexing...");
  });

  it("gives lines while waiting for Copilot", () => {
    expect(indicatorTexts({ progress: "", stopping: false, activity: null, seed: 1, look: false }).length).toBeGreaterThan(0);
  });
});
