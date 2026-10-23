import { describe, expect, it } from "vitest";
import type { IssueItem } from "./api";
import { fileOpen, fixNoticeText, fixProgressText, issueCounts, issueMetaText, issuesByFile, toggled, visibleIssues } from "./issues-view";

const issue = (o: Partial<IssueItem>): IssueItem => ({ id: "1", path: "a.js", line: 1, category: "error", message: "m", status: "open", attempts: 0, note: "", ...o });

const items = [
  issue({ id: "1", path: "a.js", category: "error" }),
  issue({ id: "2", path: "b.js", category: "secret" }),
  issue({ id: "3", path: "a.js", category: "health", status: "ignored" }),
  issue({ id: "4", path: "c.js", category: "error", status: "fixing" }),
  issue({ id: "5", path: "b.js", category: "health", status: "gave up" }),
];

describe("issues panel rules", () => {
  it("shows the kinds picked, and ignored problems only when asked", () => {
    expect(visibleIssues(items, new Set(["error", "secret", "health"]), false).map((i) => i.id)).toEqual(["1", "2", "4", "5"]);
    expect(visibleIssues(items, new Set(["health"]), true).map((i) => i.id)).toEqual(["3", "5"]);
    expect(visibleIssues(items, new Set(), true)).toEqual([]);
  });

  it("groups problems per file in the order the files first appear", () => {
    expect(issuesByFile(items).map(([p, list]) => [p, list.map((i) => i.id)])).toEqual([
      ["a.js", ["1", "3"]],
      ["b.js", ["2", "5"]],
      ["c.js", ["4"]],
    ]);
  });

  it("counts open problems per kind and the fixing, gave-up and ignored ones once each", () => {
    expect(issueCounts(items)).toEqual({ error: 1, secret: 1, health: 0, fixing: 1, gaveUp: 1, ignored: 1 });
    expect(fixProgressText(issueCounts(items))).toBe("1 being fixed. 1 still there after the fix attempts (gave up).");
    expect(fixProgressText(issueCounts([items[0]]))).toBe("");
  });

  it("opens a file when clicked, or with Expand all unless clicked closed", () => {
    const clicked = new Set(["a.js"]);
    expect(fileOpen("a.js", false, clicked)).toBe(true);
    expect(fileOpen("b.js", false, clicked)).toBe(false);
    expect(fileOpen("a.js", true, clicked)).toBe(false);
    expect(fileOpen("b.js", true, clicked)).toBe(true);
    expect([...toggled(clicked, "b.js")].sort()).toEqual(["a.js", "b.js"]);
    expect([...toggled(clicked, "a.js")]).toEqual([]);
    expect([...clicked]).toEqual(["a.js"]);
  });

  it("writes the fix answer and the line under a problem", () => {
    expect(fixNoticeText({ queued: 2, issues: 5 })).toBe("Queued 2 fix task(s) for 5 problem(s); each file is scanned again afterwards.");
    expect(fixNoticeText({ queued: 0, issues: 0 })).toBe("Nothing to fix for the chosen kinds.");
    expect(issueMetaText(issue({}))).toBe("Errors · open");
    expect(issueMetaText(issue({ category: "health", status: "gave up", attempts: 3, note: "too long" }))).toBe("Code health · gave up · 3 attempt(s) · too long");
  });
});
