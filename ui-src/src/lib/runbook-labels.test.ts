import { describe, expect, it } from "vitest";
import { attachTitle, kindBadge, lastRunLabel, resultTitle, runTitle } from "./runbook-labels";

describe("runbook labels", () => {
  it("names the kind of answer a runbook saves", () => {
    expect(kindBadge("json")).toEqual({ text: "JSON", title: "Saves JSON checked against the runbook's shape" });
    expect(kindBadge("text")).toEqual({ text: "text", title: "Saves Copilot's answer as Markdown" });
  });
  it("says when it last ran, in the fetch panel's words", () => {
    expect(lastRunLabel(null, () => "fetched 5 min ago")).toBe("never run");
    expect(lastRunLabel("2026-10-04T10:00:00", () => "fetched 5 min ago")).toBe("run 5 min ago");
  });
  it("titles Run by whether a task is running, and Result and Attach by whether it ran", () => {
    expect(runTitle(true)).toMatch(/^Add it to the queue/);
    expect(runTitle(false)).toMatch(/^Run it now/);
    expect(resultTitle(null, "Runbooks/Exports/a.md")).toBe("Not run yet");
    expect(resultTitle("2026-10-04T10:00:00", "Runbooks/Exports/a.md")).toBe("View the latest result (Runbooks/Exports/a.md)");
    expect(attachTitle(null, "Runbooks/Exports/a.md")).toBe("Not run yet");
    expect(attachTitle("2026-10-04T10:00:00", "Runbooks/Exports/a.md")).toBe("Attach @Runbooks/Exports/a.md to your message");
  });
});
