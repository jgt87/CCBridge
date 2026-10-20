import { describe, expect, it } from "vitest";
import { isActive, queueWhen, sourceLabel } from "./queue-view";

describe("queue view", () => {
  it("counts queued, running and awaiting tasks as active", () => {
    expect(["queued", "running", "awaiting"].every((s) => isActive(s as never))).toBe(true);
    expect(["done", "failed", "cancelled"].some((s) => isActive(s as never))).toBe(false);
  });

  it("names who started a task", () => {
    expect(sourceLabel("user")).toBe("you");
    expect(sourceLabel("schedule")).toBe("scheduled");
    expect(sourceLabel("mcp")).toBe("MCP");
  });

  it("gives a finished task's duration in seconds below 90 s, else minutes", () => {
    const start = "2026-10-20T10:00:00Z";
    expect(queueWhen({ created: start, started: start, finished: "2026-10-20T10:00:35Z" })).toMatch(/, 35 s$/);
    expect(queueWhen({ created: start, started: start, finished: "2026-10-20T10:05:00Z" })).toMatch(/, 5 min$/);
    expect(queueWhen({ created: start, started: null, finished: null })).not.toContain(",");
    expect(queueWhen({ created: "", started: null, finished: null })).toBe("");
  });
});
