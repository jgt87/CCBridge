import { describe, expect, it } from "vitest";
import {
  approveLabel,
  asBlocks,
  blockPlace,
  canOpenInWindow,
  decidedVia,
  doneSummary,
  hasDetails,
  needsTerminal,
  offersAllow,
  ownsLive,
  runTitle,
  shortError,
  showsOutput,
  shownStatus,
  statusClass,
  statusLabel,
  verbFor,
} from "./action-card-view";

const file = (exists: boolean) => ({ path: "a.ts", exists, old: "", new: "x" });

describe("action card view rules", () => {
  it("names the verb, or shows the action itself", () => {
    expect(verbFor("runbook")).toBe("Run runbook");
    expect(verbFor("glob")).toBe("List");
    expect(verbFor("todo")).toBe("Plan");
    expect(verbFor("web")).toBe("web");
  });

  it("labels and colours each status, and shows a sent decision as running", () => {
    expect(statusLabel("awaiting")).toBe("needs approval");
    expect(statusLabel("ok")).toBe("done");
    expect(statusLabel("already applied")).toBe("already applied (verified)");
    expect(statusLabel("skipped")).toBe("skipped (plan mode)");
    expect(statusLabel("interrupted")).toBe("interrupted (StreamHub restarted)");
    expect(statusLabel("ambiguous")).toBe("needs a more exact SEARCH");
    expect(statusLabel("other")).toBe("other");
    expect(statusClass("failed")).toBe("text-(--kit-error)");
    expect(statusClass("awaiting")).toBe("font-medium text-foreground");
    expect(statusClass("other")).toBeUndefined();
    expect(shownStatus("awaiting", true)).toBe("running");
    expect(shownStatus("awaiting", false)).toBe("awaiting");
    expect(shownStatus("ok", true)).toBe("ok");
  });

  it("words the approve button by the kind of step", () => {
    const at = (action: string, exists = false) => approveLabel({ action, target: "", status: "awaiting", preview: file(exists) });
    expect(at("web")).toBe("Read");
    expect(at("sql")).toBe("Run query");
    expect(at("remember")).toBe("Save note");
    expect(at("runbook")).toBe("Run runbook");
    expect(at("write")).toBe("Create file");
    expect(at("edit", true)).toBe("Apply change");
    expect(at("move")).toBe("Approve");
  });

  it("keeps only the reason on the red line, at most 320 characters", () => {
    expect(shortError("Not found\nCurrent lines: 1")).toBe("Not found");
    expect(shortError("SEARCH missed. The closest place is 4")).toBe("SEARCH missed.");
    expect(shortError("x What differs: a")).toBe("x");
    const long = shortError("a".repeat(400));
    expect(long).toHaveLength(320);
    expect(long.endsWith("...")).toBe(true);
  });

  it("reads change blocks as one object or a list and says where each is", () => {
    const b = { index: 0, oldStart: 4, oldCount: 3, newStart: 4, newCount: 2, first: "x" };
    expect(asBlocks(null)).toEqual([]);
    expect(asBlocks(b)).toEqual([b]);
    expect(asBlocks([b, { first: "no index" } as never])).toEqual([b]);
    expect(blockPlace(b)).toBe("line 4-6 (+2 -3)");
    expect(blockPlace({ ...b, oldCount: 1 })).toBe("line 4 (+2 -1)");
    expect(blockPlace({ ...b, oldStart: 10, oldCount: 0, newCount: 1 })).toBe("after line 9 (+1 -0)");
  });

  it("decides which parts of the card show", () => {
    const run = { action: "run", target: "npm test", status: "ok" };
    expect(hasDetails(run)).toBe(true);
    expect(hasDetails({ action: "read", target: "a", status: "ok" })).toBe(false);
    expect(hasDetails({ action: "read", target: "a", status: "ok", reasons: ["r"] })).toBe(true);
    expect(decidedVia("user")).toBe("");
    expect(decidedVia(undefined)).toBe("");
    expect(decidedVia("mcp")).toBe("MCP");
    expect(decidedVia("api")).toBe("API");
    expect(needsTerminal({ ...run, output: "needs a terminal" })).toBe(true);
    expect(needsTerminal({ ...run, code: "RUN-INTERACTIVE" })).toBe(true);
    expect(needsTerminal(run)).toBe(false);
    const edit = { action: "edit", target: "a", status: "ok", output: "done" };
    expect(showsOutput(edit, false, false)).toBe(true);
    expect(showsOutput(edit, true, false)).toBe(false);
    expect(showsOutput(edit, false, true)).toBe(false);
    expect(showsOutput({ ...edit, status: "failed" }, false, true)).toBe(true);
    expect(showsOutput({ ...run, output: "x" }, false, false)).toBe(false);
    expect(canOpenInWindow(run, false, false)).toBe(true);
    expect(canOpenInWindow(run, true, false)).toBe(false);
    expect(canOpenInWindow(run, false, true)).toBe(false);
    expect(canOpenInWindow(run, false, true, "question")).toBe(true);
    expect(canOpenInWindow(run, false, true, "stuck")).toBe(true);
    expect(canOpenInWindow({ ...run, target: "  " }, false, false)).toBe(false);
    const web = { action: "web", target: "x", status: "awaiting", allowOptions: ["example.org"] };
    expect(offersAllow(web, true)).toBe(true);
    expect(offersAllow(web, false)).toBe(false);
    expect(offersAllow({ ...web, allowOptions: [] }, true)).toBe(false);
    expect(doneSummary({ ...edit, summary: "Changed 2 lines" })).toBe("Changed 2 lines");
    expect(doneSummary({ ...edit, summary: "done" })).toBe("");
    expect(doneSummary({ ...edit, status: "failed", summary: "x" })).toBe("");
    expect(doneSummary({ ...edit, status: "already applied", summary: "x" })).toBe("x");
  });

  it("takes the live output only for its own running command", () => {
    const running = { id: "a1", action: "run", target: "npm test", status: "running" };
    expect(ownsLive(running, "a1")).toBe(true);
    expect(ownsLive(running, "b2")).toBe(false);
    expect(ownsLive(running, undefined)).toBe(false);
    expect(ownsLive({ ...running, status: "ok" }, "a1")).toBe(false);
    expect(ownsLive({ ...running, action: "edit" }, "a1")).toBe(false);
  });
});

describe("runTitle", () => {
  it("names the program, and the script it runs", () => {
    expect(runTitle(`powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=(Get-Content 'x'); 'ok'"`)).toBe("powershell");
    expect(runTitle("powershell -NoProfile -ExecutionPolicy Bypass -File Work/Test-Dashboard.ps1")).toBe("powershell Work/Test-Dashboard.ps1");
    expect(runTitle(`"C:\\Program Files\\nodejs\\node.exe" scripts/build.js --watch`)).toBe("node scripts/build.js");
    expect(runTitle("python -u Scripts/refresh.py")).toBe("python Scripts/refresh.py");
    expect(runTitle("npm run build")).toBe("npm");
    expect(runTitle("cmd /c dir")).toBe("cmd");
    expect(runTitle("   ")).toBe("");
  });
});
