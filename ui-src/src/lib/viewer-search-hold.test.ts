import { describe, expect, it } from "vitest";
import { actionTitle, filterActions, nextIndex, prevIndex } from "./action-search";
import { isMarkdownPath, previewImageSrc, viewerBody } from "./file-viewer";
import { holdCompleted, holdFillClass, holdIconVariant } from "./hold-button";

describe("file viewer", () => {
  it("shows the diff first, then an image, rendered Markdown, else code", () => {
    expect(viewerBody("a.png", true, "/p/", false)).toBe("diff");
    expect(viewerBody("img/a.PNG", false, "/p/", false)).toBe("image");
    // Without the preview address an image cannot load: its text shows as code.
    expect(viewerBody("a.png", false, undefined, false)).toBe("code");
    expect(viewerBody("README.md", false, "/p/", false)).toBe("markdown");
    expect(viewerBody("notes.markdown", false, "/p/", true)).toBe("code");
    expect(viewerBody("src/app.ts", false, "/p/", false)).toBe("code");
    expect(isMarkdownPath("a.MD")).toBe(true);
    expect(isMarkdownPath("a.md.txt")).toBe(false);
  });

  it("encodes each part of an image's path, keeping the slashes", () => {
    expect(previewImageSrc("/preview/t/", "img/my pic#1.png")).toBe("/preview/t/img/my%20pic%231.png");
  });
});

describe("command palette search", () => {
  const actions = [
    { label: "Open file", description: "Pick a project file" },
    { label: "New chat" },
    { label: "Settings", description: "Open the settings" },
  ];

  it("matches label or description in any case, trimmed, up to the limit", () => {
    expect(filterActions(actions, "", 12)).toEqual(actions);
    expect(filterActions(actions, "  OPEN ", 12).map((a) => a.label)).toEqual(["Open file", "Settings"]);
    expect(filterActions(actions, "open", 1).map((a) => a.label)).toEqual(["Open file"]);
    expect(filterActions(actions, "nothing", 12)).toEqual([]);
  });

  it("wraps the arrow keys around the list", () => {
    expect(nextIndex(0, 3)).toBe(1);
    expect(nextIndex(2, 3)).toBe(0);
    expect(prevIndex(1, 3)).toBe(0);
    expect(prevIndex(0, 3)).toBe(2);
  });

  it("gives a row's whole text as its hover title", () => {
    expect(actionTitle(actions[0])).toBe("Open file: Pick a project file");
    expect(actionTitle(actions[1])).toBe("New chat");
  });
});

describe("hold button", () => {
  it("colours the fill by variant, none without one", () => {
    expect(holdFillClass("grey")).toBe("bg-black/10 dark:bg-white/15");
    expect(holdFillClass("red")).toContain("bg-red-200/30");
    expect(holdFillClass(null)).toBe("");
    expect(holdFillClass(undefined)).toBe("");
  });

  it("shows the red icon when no variant is given", () => {
    expect(holdIconVariant(null)).toBe("red");
    expect(holdIconVariant("blue")).toBe("blue");
  });

  it("completes only while still held and after the whole time (50 ms leeway)", () => {
    expect(holdCompleted(true, 1000, 2150, 1200)).toBe(true);
    expect(holdCompleted(true, 1000, 2149, 1200)).toBe(false);
    expect(holdCompleted(false, 1000, 3000, 1200)).toBe(false);
  });
});
