import { describe, expect, it } from "vitest";
import { intakeFilesLine, intakeSavedText } from "./intake-card";

describe("intake card texts", () => {
  it("names up to four files and counts the rest", () => {
    expect(intakeFilesLine({ label: "Data", count: 2, files: ["a.csv", "b.csv"] })).toBe("Data (2): a.csv, b.csv");
    expect(intakeFilesLine({ label: "Images", count: 6, files: ["1", "2", "3", "4", "5", "6"] })).toBe("Images (6): 1, 2, 3, 4 and 2 more");
  });

  it("says what was moved and whether Copilot starts now", () => {
    expect(intakeSavedText({ moved: [], queued: null })).toBe("Saved. Copilot gets this with every task.");
    expect(intakeSavedText({ moved: ["a.csv", "b.csv"], queued: "t1" })).toBe("Saved. 2 data file(s) moved into Source/. Copilot is on it now.");
  });
});
