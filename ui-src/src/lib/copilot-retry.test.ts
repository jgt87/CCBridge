import { describe, expect, it } from "vitest";
import { copilotRetry } from "./copilot-retry";

describe("copilotRetry", () => {
  it("offers nothing while connected or connecting", () => {
    expect(copilotRetry("ready", "")).toEqual({ kind: "none" });
    expect(copilotRetry("connecting", "2026-10-22T10:42:00")).toEqual({ kind: "none" });
  });
  it("says when StreamHub tries again by itself", () => {
    expect(copilotRetry("error", new Date(2026, 9, 22, 10, 42, 30).toISOString())).toEqual({ kind: "auto", at: "10:42" });
  });
  it("offers the check button once StreamHub stopped trying by itself", () => {
    expect(copilotRetry("error", "")).toEqual({ kind: "stopped" });
    expect(copilotRetry("error", undefined)).toEqual({ kind: "stopped" });
  });
});
