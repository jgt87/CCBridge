import { describe, expect, it } from "vitest";
import { indexState } from "./index-state";

describe("indexState", () => {
  it("says what the index line shows", () => {
    expect(indexState(true, 0, 0)).toBe("busy");
    expect(indexState(true, 12, 3)).toBe("busy");
    expect(indexState(false, 0, 0)).toBe("never");
    expect(indexState(false, 12, 0)).toBe("clean");
    expect(indexState(false, 12, 3)).toBe("issues");
  });
});
