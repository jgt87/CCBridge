import { describe, expect, it } from "vitest";
import { isImagePath, parseAgent, parseClarify, runWindowList, sendOptions, showClarify, withAttached } from "./app-view";

describe("app view helpers", () => {
  it("reads the remembered choices, falling back to Auto and Clarify off", () => {
    expect(parseClarify("1")).toBe(true);
    expect(parseClarify("0")).toBe(false);
    expect(parseClarify(null)).toBe(false);
    expect(showClarify(true)).toBe("1");
    expect(parseAgent("researcher")).toBe("researcher");
    expect(parseAgent("analyst")).toBe("analyst");
    expect(parseAgent("copilot")).toBe("copilot");
    expect(parseAgent("other")).toBe("auto");
    expect(parseAgent(null)).toBe("auto");
  });

  it("sends Clarify first with Copilot and Auto, never with a named agent", () => {
    expect(sendOptions("copilot", true)).toEqual({ clarify: true });
    expect(sendOptions("auto", false)).toEqual({ agent: "auto", clarify: false });
    expect(sendOptions("researcher", true)).toEqual({ agent: "researcher" });
  });

  it("knows image files by their extension", () => {
    expect(isImagePath("img/a.PNG")).toBe(true);
    expect(isImagePath("a.jpeg")).toBe(true);
    expect(isImagePath("a.svg")).toBe(true);
    expect(isImagePath("a.png.txt")).toBe(false);
  });

  it("makes one console window or none a list", () => {
    const w = { id: "1" } as never;
    expect(runWindowList(undefined)).toEqual([]);
    expect(runWindowList(w)).toEqual([w]);
    expect(runWindowList([w, w])).toEqual([w, w]);
  });

  it("adds @path to the draft with one space between", () => {
    expect(withAttached("", "a.md")).toBe("@a.md ");
    expect(withAttached("look at", "a.md")).toBe("look at @a.md ");
    expect(withAttached("look at ", "a.md")).toBe("look at @a.md ");
  });
});
