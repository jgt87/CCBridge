import { describe, expect, it } from "vitest";
import { stepText } from "./chains-panel";

describe("stepText", () => {
  it("shows a step as one short line", () => {
    expect(stepText({ kind: "runbook", target: "meetings" })).toBe("runbook meetings");
    expect(stepText({ kind: "script", target: "Scripts/x.ps1", args: "-Week 1" })).toBe("script Scripts/x.ps1 -Week 1");
    expect(stepText({ kind: "runbook", target: "summary", with: ["a.json"] })).toBe("runbook summary + 1 file");
    expect(stepText({ kind: "runbook", target: "summary", with: ["a.json", "b.json"] })).toBe("runbook summary + 2 files");
  });
});
