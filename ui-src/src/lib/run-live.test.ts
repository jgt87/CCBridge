import { describe, expect, it } from "vitest";
import { formatElapsed, liveLines, parseRunOutput, waitText } from "./run-live";

describe("run-live", () => {
  it("formats elapsed time like a clock", () => {
    expect(formatElapsed(7)).toBe("0:07");
    expect(formatElapsed(102)).toBe("1:42");
    expect(formatElapsed(3723)).toBe("1:02:03");
  });
  it("says what a waiting command looks like", () => {
    expect(waitText({ state: "running", quietSec: 2 })).toBe("");
    expect(waitText({ state: "question", quietSec: 4 })).toMatch(/Open in a window/);
    expect(waitText({ state: "stuck", quietSec: 45 })).toMatch(/No output for 0:45 and no CPU use/);
    expect(waitText({ state: "quiet", quietSec: 31 })).toMatch(/still working/);
  });
  it("takes lines as a list or one string", () => {
    expect(liveLines(["a", "b"])).toEqual(["a", "b"]);
    expect(liveLines("one line")).toEqual(["one line"]);
    expect(liveLines(null)).toEqual([]);
  });
  it("splits a finished run into status, console lines and notes", () => {
    const r = parseRunOutput("exit code 1\n~~~~\nerror: x\n  -->  schema.prisma:4\n~~~~\nThis command needs an interactive terminal");
    expect(r.status).toBe("exit code 1");
    expect(r.lines).toEqual(["error: x", "  -->  schema.prisma:4"]);
    expect(r.notes).toMatch(/interactive terminal/);
    expect(parseRunOutput("exit code 0\n~~~~\n\n~~~~").lines).toEqual([]);
    expect(parseRunOutput("plain text").lines).toEqual(["plain text"]);
  });
});
