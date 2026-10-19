import { describe, expect, it } from "vitest";
import type { FileInfo, ScheduleItem } from "./api";
import {
  addTime,
  buildScheduleSpec,
  initialDays,
  initialTitle,
  missingParts,
  nextHour,
  pickFile,
  pickableFiles,
  repeatFor,
  withPendingTime,
} from "./schedule-form";

const item = (over: Partial<ScheduleItem>) => ({ kind: "chat", title: "", repeat: "daily", ...over }) as ScheduleItem;
const file = (path: string) => ({ path }) as FileInfo;

describe("repeatFor", () => {
  it("names every day, weekdays or weekly", () => {
    expect(repeatFor([0, 1, 2, 3, 4, 5, 6])).toBe("daily");
    expect(repeatFor([5, 4, 3, 2, 1])).toBe("weekdays");
    expect(repeatFor([1, 2, 3, 4, 6])).toBe("weekly");
    expect(repeatFor([1])).toBe("weekly");
  });
});

describe("nextHour", () => {
  it("gives the next full hour as a local datetime-local value", () => {
    const now = new Date(2026, 9, 19, 13, 45).getTime();
    expect(nextHour(now)).toBe("2026-10-19T14:00");
    expect(nextHour(new Date(2026, 11, 31, 23, 10).getTime())).toBe("2027-01-01T00:00");
  });
});

describe("initial form values", () => {
  it("takes the days from an existing schedule", () => {
    expect(initialDays(undefined)).toEqual([1, 2, 3, 4, 5]);
    expect(initialDays(item({ repeat: "once" }))).toEqual([1, 2, 3, 4, 5]);
    expect(initialDays(item({ repeat: "daily" }))).toEqual([1, 2, 3, 4, 5, 6, 0]);
    expect(initialDays(item({ repeat: "weekdays" }))).toEqual([1, 2, 3, 4, 5]);
    expect(initialDays(item({ repeat: "weekly", days: [2, 4] }))).toEqual([2, 4]);
    expect(initialDays(item({ repeat: "weekly", days: [] }))).toEqual([1, 2, 3, 4, 5]);
  });

  it("keeps only a title the user typed", () => {
    expect(initialTitle(undefined)).toBe("");
    expect(initialTitle(item({ text: "Update  the\nreport", title: "Update the report" }))).toBe("");
    const long = "x".repeat(130);
    expect(initialTitle(item({ text: long, title: `${"x".repeat(117)}...` }))).toBe("");
    expect(initialTitle(item({ kind: "runbook", name: "mail", title: "runbook: mail" }))).toBe("");
    expect(initialTitle(item({ kind: "runbook", name: "mail", title: "Morning mail" }))).toBe("Morning mail");
  });
});

describe("the @ picker", () => {
  it("lists Markdown files first, filtered, at most 50", () => {
    const files = [file("b.js"), file("a.md"), file("Runbooks/x.runbook.md"), file("c.txt")];
    expect(pickableFiles(files, "").map((f) => f.path)).toEqual(["a.md", "Runbooks/x.runbook.md", "b.js", "c.txt"]);
    expect(pickableFiles(files, " RUNBOOK ").map((f) => f.path)).toEqual(["Runbooks/x.runbook.md"]);
    expect(pickableFiles(Array.from({ length: 60 }, (_, i) => file(`f${i}.md`)), "")).toHaveLength(50);
  });

  it("runs a runbook, attaches other files and refuses a path with a space", () => {
    expect(pickFile("Runbooks/mail.runbook.md", "")).toEqual({ target: "runbook:mail" });
    expect(pickFile("docs/steps.md", "")).toEqual({ target: "chat", text: "Follow the instructions in @docs/steps.md" });
    expect(pickFile("docs/steps.md", "Do this  ")).toEqual({ target: "chat", text: "Do this @docs/steps.md" });
    expect(pickFile("my docs/a.md", "")).toEqual({ error: expect.stringContaining("my docs/a.md has a space") });
  });
});

describe("times", () => {
  it("adds a valid new time once, sorted", () => {
    expect(addTime(["09:00"], "08:30")).toEqual(["08:30", "09:00"]);
    expect(addTime(["09:00"], "09:00")).toEqual(["09:00"]);
    expect(addTime(["09:00"], "25:00")).toEqual(["09:00"]);
    expect(addTime(["09:00"], "")).toEqual(["09:00"]);
  });

  it("counts a typed time that was not added yet", () => {
    expect(withPendingTime(["09:00"], "07:15")).toEqual(["07:15", "09:00"]);
    expect(withPendingTime(["09:00"], "09:00")).toEqual(["09:00"]);
    expect(withPendingTime(["09:00"], "7:15")).toEqual(["09:00"]);
  });
});

describe("saving", () => {
  const base = { target: "chat", text: "Hi", title: "  ", mode: "repeat" as const, at: "2026-10-19T14:00", days: [1, 2, 3, 4, 5], times: ["08:00"] };

  it("builds the spec for a message or a named item", () => {
    expect(buildScheduleSpec(base)).toEqual({ kind: "chat", text: "Hi", name: undefined, title: undefined, repeat: "weekdays", days: [1, 2, 3, 4, 5], times: ["08:00"] });
    expect(buildScheduleSpec({ ...base, target: "script:Scripts/a:b.ps1", mode: "once", title: " T " })).toEqual({
      kind: "script",
      text: undefined,
      name: "Scripts/a:b.ps1",
      title: "T",
      repeat: "once",
      at: "2026-10-19T14:00",
    });
  });

  it("says what is still missing", () => {
    expect(missingParts(base)).toEqual([]);
    expect(missingParts({ ...base, text: " " })).toEqual(["write the message"]);
    expect(missingParts({ ...base, target: "runbook:" })).toEqual(["pick what runs"]);
    expect(missingParts({ ...base, mode: "once", at: "" })).toEqual(["pick the date and time"]);
    expect(missingParts({ ...base, days: [], times: [] })).toEqual(["pick at least one day", "add a time"]);
  });
});
