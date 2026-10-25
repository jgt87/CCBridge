import { describe, expect, it } from "vitest";
import type { TidyItem } from "@/lib/api";
import { formatSize, selectionSummary, tidyGroups, tidyItemName, tidyQueuedText, toggleAll, toggled } from "./tidy-card-view";

const item = (id: string, kind: TidyItem["kind"], path: string, size: number, selector = ""): TidyItem => ({ id, kind, path, selector, reason: "unused", size });
const items = [item("a", "work", "Work/x.txt", 100), item("b", "file", "js/old.js", 2048), item("c", "css-rule", "css/site.css", 30, ".gone")];

describe("tidy-up card", () => {
  it("writes sizes people read", () => {
    expect(formatSize(512)).toBe("512 bytes");
    expect(formatSize(3482)).toBe("3.4 KB");
    expect(formatSize(5 * 1024 * 1024)).toBe("5 MB");
  });

  it("groups the items by kind in a fixed order, leaving empty kinds out", () => {
    const g = tidyGroups(items);
    expect(g.map((x) => x.kind)).toEqual(["file", "css-rule", "work"]);
    expect(g[0].label).toBe("Script and style files nothing loads");
  });

  it("names a style rule with its stylesheet", () => {
    expect(tidyItemName(items[2])).toBe(".gone in css/site.css");
    expect(tidyItemName(items[1])).toBe("js/old.js");
  });

  it("counts the selection and its size", () => {
    expect(selectionSummary(items, new Set()).text).toBe("Nothing selected");
    const s = selectionSummary(items, new Set(["a", "b"]));
    expect(s.count).toBe(2);
    expect(s.text).toBe("2 selected (2.1 KB)");
  });

  it("selects all, then none, and toggles one", () => {
    const all = toggleAll(items, new Set());
    expect([...all].sort()).toEqual(["a", "b", "c"]);
    expect(toggleAll(items, all).size).toBe(0);
    expect([...toggled(new Set(["a"]), "b")].sort()).toEqual(["a", "b"]);
    expect([...toggled(new Set(["a"]), "a")]).toEqual([]);
  });

  it("says that items are checked again and can be undone", () => {
    expect(tidyQueuedText(3)).toMatch(/Removing 3 item\(s\)\. Each is checked again first/);
  });
});
