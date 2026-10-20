import { describe, expect, it } from "vitest";
import type { ChainItem } from "@/lib/api";
import { canAddStep, runTitle, stepCount, stepText, stepToAdd } from "./chains";

const chain = (steps: number, problems: string[] = []): ChainItem => ({
  name: "c",
  title: "C",
  path: "Runbooks/c.chain.md",
  stopOnError: true,
  steps: Array.from({ length: steps }, (_, i) => ({ kind: "runbook" as const, target: `r${i}` })),
  problems,
});

describe("chain steps", () => {
  it("shows a download step by its file name and place", () => {
    expect(stepText({ kind: "download", target: "https://x.sharepoint.com/s/Shared%20Docs/sales%201.csv?web=1", args: "Downloads/s.csv" })).toBe("download sales 1.csv to Downloads/s.csv");
    expect(stepText({ kind: "download", target: "https://x.sharepoint.com/a/b.xlsx" })).toBe("download b.xlsx to Downloads/");
    expect(stepText({ kind: "fetch", target: "notes", args: "ignored" })).toBe("fetch notes");
    expect(stepText({ kind: "script", target: "Scripts/x.ps1" })).toBe("script Scripts/x.ps1");
  });

  it("counts steps and names why a chain cannot run", () => {
    expect(stepCount(1)).toBe("1 step");
    expect(stepCount(0)).toBe("0 steps");
    expect(runTitle(chain(0), false)).toBe("Add a step first");
    expect(runTitle(chain(2, ["unknown runbook"]), false)).toBe("Fix the steps first");
    expect(runTitle(chain(2), true)).toBe("Add it to the queue");
    expect(runTitle(chain(2), false)).toBe("Run the steps now, one after another");
  });

  it("builds the step the add form describes", () => {
    expect(stepToAdd("runbook:weekly", "-x", "")).toEqual({ kind: "runbook", target: "weekly", args: "" });
    expect(stepToAdd("script:Scripts/a.ps1", " -Week 1 ", "")).toEqual({ kind: "script", target: "Scripts/a.ps1", args: " -Week 1 " });
    expect(stepToAdd("download:", " Downloads/a.csv ", " https://x/a.csv ")).toEqual({ kind: "download", target: "https://x/a.csv", args: "Downloads/a.csv" });
  });

  it("allows Add only with a pick, while not saving, and a link for a download", () => {
    expect(canAddStep("", "", false)).toBe(false);
    expect(canAddStep("runbook:a", "", false)).toBe(true);
    expect(canAddStep("runbook:a", "", true)).toBe(false);
    expect(canAddStep("download:", "  ", false)).toBe(false);
    expect(canAddStep("download:", "https://x", false)).toBe(true);
  });
});
