import { describe, expect, it } from "vitest";
import { runbookRows } from "./runbooks-panel";

describe("runbookRows", () => {
  it("lists both kinds of runbook in one list, by title, with their file and result", () => {
    const rows = runbookRows(
      [{ name: "meetings", title: "Meetings next week", path: "Runbooks/meetings.runbook.md", output: "Runbooks/Exports/meetings.json", lastRun: null }],
      [{ name: "agenda", prompt: "List today's agenda", promptPath: "Runbooks/agenda.prompt.md", output: "Runbooks/Exports/agenda.md", fetchedAt: "2026-10-04T10:00:00", outputSize: 10, sources: "work" }],
    );
    expect(rows.map((r) => `${r.kind}:${r.name}`)).toEqual(["text:agenda", "json:meetings"]);
    expect(rows[0]).toMatchObject({ file: "Runbooks/agenda.prompt.md", output: "Runbooks/Exports/agenda.md", lastRun: "2026-10-04T10:00:00", extra: "work data only" });
    expect(rows[1]).toMatchObject({ file: "Runbooks/meetings.runbook.md", lastRun: null });
  });
});
