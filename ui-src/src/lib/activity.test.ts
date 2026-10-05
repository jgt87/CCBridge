import { describe, expect, it } from "vitest";
import { isIndexing } from "./activity";
import { activityTexts } from "./thinking-texts";

const base = { done: 0, total: 0, current: "", background: false };

describe("isIndexing", () => {
  it("is the index only for index work (or an older server without a kind)", () => {
    expect(isIndexing({ ...base, label: "Scanning 3 changed file(s) for issues", kind: "index" })).toBe(true);
    expect(isIndexing({ ...base, label: "Indexing" })).toBe(true);
    expect(isIndexing({ ...base, label: "Checking index.html in a browser tab", kind: "page" })).toBe(false);
    expect(isIndexing(null)).toBe(false);
  });
});

describe("activityTexts", () => {
  it("starts with the plain line and repeats it between the light lines", () => {
    const t = activityTexts("Running the tests...", "tests", 7);
    expect(t[0]).toBe("Running the tests...");
    expect(t.filter((x) => x === "Running the tests...").length).toBeGreaterThan(1);
    expect(t.length).toBeGreaterThan(3);
  });
  it("shows only the plain line for a kind without light lines", () => {
    expect(activityTexts("Working...", "unknown", 1)).toEqual(["Working..."]);
  });
});
