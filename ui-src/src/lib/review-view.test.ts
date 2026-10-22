import { describe, expect, it } from "vitest";
import type { ReviewFinding, ReviewSummary } from "./api";
import { canStartReview, defaultPicked, estimateText, findingGroups, findingTags, reviewCounts, splitPaths, toggleFocus, togglePicked } from "./review-view";

const finding = (id: string, over: Partial<ReviewFinding> = {}): ReviewFinding => ({
  id,
  file: "src/app.js",
  line: 3,
  severity: "high",
  category: "bugs",
  title: "T",
  detail: "",
  quote: "",
  suggestion: "",
  status: "verified",
  ...over,
});

describe("review view", () => {
  it("splits typed paths on commas and new lines", () => {
    expect(splitPaths(" src, index.html\n\n lib ,")).toEqual(["src", "index.html", "lib"]);
    expect(splitPaths("")).toEqual([]);
  });

  it("toggles focus areas and picked ids", () => {
    expect(toggleFocus(["bugs", "tests"], "bugs")).toEqual(["tests"]);
    expect(toggleFocus(["bugs"], "tests")).toEqual(["bugs", "tests"]);
    const cur = new Set(["a"]);
    expect([...togglePicked(cur, "a")]).toEqual([]);
    expect([...togglePicked(cur, "b")]).toEqual(["a", "b"]);
    expect([...cur]).toEqual(["a"]);
  });

  it("ticks verified and general findings that are not low, queued or ignored", () => {
    const list = [
      finding("v"),
      finding("g", { status: "general", severity: "medium" }),
      finding("u", { status: "unverified" }),
      finding("q", { fixQueueId: "x" }),
      finding("i", { ignored: true }),
      finding("l", { severity: "low" }),
    ];
    expect([...defaultPicked(list)]).toEqual(["v", "g"]);
  });

  it("says the estimate, the error or what is never reviewed", () => {
    expect(estimateText("No such folder", { files: 2, messages: 1, scopeText: "x" })).toBe("No such folder");
    expect(estimateText("", null)).toBe("Build output, lock files, data and Source/ are never reviewed.");
    expect(estimateText("", { files: 4, messages: 2, scopeText: "src" })).toBe("4 file(s), about 2 Copilot message(s). Read-only: nothing is changed.");
    expect(estimateText("", { files: 0, messages: 0, scopeText: "src" })).toBe("No code files in src.");
  });

  it("writes a review's counts, with unverified and ignored only when there are any", () => {
    const r: ReviewSummary = { id: "1", created: "", scopeText: "Whole project", files: 3, messages: 1, high: 1, medium: 2, low: 0, unverified: 0, report: "r.md" };
    expect(reviewCounts(r)).toBe("Whole project · 1 high · 2 medium · 0 low");
    expect(reviewCounts({ ...r, unverified: 2, ignored: 1 })).toBe("Whole project · 1 high · 2 medium · 0 low · 2 unverified · 1 ignored");
  });

  it("groups findings by severity, unverified last, empty groups left out", () => {
    const list = [finding("l", { severity: "low" }), finding("u", { status: "unverified", severity: "high" }), finding("h"), finding("g", { status: "general" })];
    expect(findingGroups(list).map((g) => [g.key, g.list.map((f) => f.id)])).toEqual([
      ["high", ["h", "g"]],
      ["low", ["l"]],
      ["unverified", ["u"]],
    ]);
    expect(findingGroups([])).toEqual([]);
  });

  it("labels a finding's state in a fixed order", () => {
    expect(findingTags(finding("a"))).toEqual([]);
    expect(findingTags(finding("a", { status: "unverified", fixQueueId: "q", ignored: true }))).toEqual(["unverified", "fix queued", "ignored"]);
  });
});

describe("latestOnly", () => {
  it("drops a load that arrives after a newer one was asked for", async () => {
    const { latestOnly } = await import("./review-view");
    const latest = latestOnly<string, string>();
    let finishA: (v: string) => void = () => {};
    const a = latest("A", () => new Promise<string>((r) => { finishA = r; }));
    const b = latest("B", () => Promise.resolve("report B"));
    await expect(b).resolves.toBe("report B");
    finishA("report A");
    await expect(a).resolves.toBeNull();
    // The latest one still shows when it is the slow one.
    const c = latest("C", () => Promise.resolve("report C"));
    await expect(c).resolves.toBe("report C");
  });

  it("allows a start only with code files, a focus and nothing starting", () => {
    const est = { files: 3, messages: 1, scopeText: "the project" };
    expect(canStartReview(false, est, ["bugs"])).toBe(true);
    expect(canStartReview(true, est, ["bugs"])).toBe(false);
    expect(canStartReview(false, { ...est, files: 0 }, ["bugs"])).toBe(false);
    expect(canStartReview(false, null, ["bugs"])).toBe(false);
    expect(canStartReview(false, est, [])).toBe(false);
  });
});
