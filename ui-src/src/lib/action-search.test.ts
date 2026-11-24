import { describe, expect, it } from "vitest";
import { filterActions, nextIndex, prevIndex, resultCountText } from "./action-search";

describe("command palette search", () => {
  it("matches label or description, any case, at most max", () => {
    const list = [{ label: "New chat" }, { label: "Settings", description: "Open the settings" }, { label: "Export" }];
    expect(filterActions(list, "SETT", 5).map((a) => a.label)).toEqual(["Settings"]);
    expect(filterActions(list, "", 2)).toHaveLength(2);
  });

  it("wraps the arrow keys", () => {
    expect(nextIndex(2, 3)).toBe(0);
    expect(prevIndex(0, 3)).toBe(2);
  });

  it("says how many rows match, for screen readers", () => {
    expect(resultCountText(0)).toBe("No matches");
    expect(resultCountText(1)).toBe("1 match");
    expect(resultCountText(12)).toBe("12 matches");
  });
});
