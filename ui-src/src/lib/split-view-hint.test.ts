import { describe, expect, it } from "vitest";
import { splitHintEligible } from "./split-view-hint";

const EDGE = "Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 Chrome/130.0 Safari/537.36 Edg/130.0";
const CHROME = "Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 Chrome/130.0 Safari/537.36";

describe("split screen hint", () => {
  it("shows once, in Edge, when the app is a tab in the Copilot window", () => {
    expect(splitHintEligible(EDGE, undefined, false, false)).toBe(true);
    expect(splitHintEligible(EDGE, "copilot-tab", false, false)).toBe(true);
  });

  it("stays away in other browsers, other window choices, or once shown", () => {
    expect(splitHintEligible(CHROME, "copilot-tab", false, false)).toBe(false);
    expect(splitHintEligible(EDGE, "side-by-side", false, false)).toBe(false);
    expect(splitHintEligible(EDGE, "copilot-tab", true, false)).toBe(false);
    expect(splitHintEligible(EDGE, "copilot-tab", false, true)).toBe(false);
  });
});
