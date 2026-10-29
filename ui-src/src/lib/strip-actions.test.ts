import { describe, expect, it } from "vitest";
import { stripActionBlocks } from "./diff";

const F3 = "```";
const F4 = "````";

describe("stripActionBlocks", () => {
  it("hides action blocks in the ACTION form and the older form, and keeps other code", () => {
    const reply = [
      "Let me look.",
      `${F3}text`, "ACTION read", "index.html", F3,
      `${F4}text`, "ACTION write a.txt", "hi", F4,
      `${F3}read`, "b.txt", F3,
      `${F3}text`, "Plain text, not an action.", F3,
      `${F3}text`, "find the bug yourself", F3,
      `${F3}python`, "print(1)", F3,
      "Done for now.",
    ].join("\n");
    const out = stripActionBlocks(reply);
    expect(out).not.toContain("ACTION");
    expect(out).not.toContain("b.txt");
    expect(out).toContain("Plain text, not an action.");
    expect(out).toContain("find the bug yourself"); // not carried out, so not hidden either
    expect(out).toContain("print(1)");
    expect(out).toContain("Done for now.");
  });

  it("hides move, delete, refs, changes and test only in the ACTION form (lib/Protocol.psm1 does the same)", () => {
    const reply = [
      `${F3}text`, "ACTION move", "app.js -> js/app.js", F3,
      `${F3}text`, "ACTION delete", "old.css", F3,
      `${F3}text`, "ACTION refs", "greet", F3,
      `${F3}text`, "ACTION changes", F3,
      `${F3}text`, "ACTION test", F3,
      `${F3}test`, "expect(sum(1, 2)).toBe(3)", F3,
      `${F3}delete`, "a sample block", F3,
    ].join("\n");
    const out = stripActionBlocks(reply);
    expect(out).not.toContain("ACTION");
    expect(out).not.toContain("js/app.js");
    expect(out).toContain("expect(sum(1, 2)).toBe(3)");
    expect(out).toContain("a sample block");
  });
});
