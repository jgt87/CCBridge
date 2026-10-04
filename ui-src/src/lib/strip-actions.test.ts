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
});
