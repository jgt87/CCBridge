import { describe, expect, it } from "vitest";
import { isTodoChange, todoChange } from "./todo-list";

describe("to-do lists in a change", () => {
  it("knows a to-do file by name or by its items, and not other Markdown", () => {
    expect(isTodoChange("TODO.md", "- [ ] a\n- [x] b")).toBe(true);
    expect(isTodoChange("notes/steps.md", "# Steps\n- [ ] a\n- [ ] b\n- [x] c")).toBe(true);
    expect(isTodoChange("README.md", "# App\nSome text\nMore text\nAnd more\n- [ ] a\n- [ ] b\nEven more")).toBe(false);
    expect(isTodoChange("todo.js", "- [ ] a\n- [x] b")).toBe(false);
  });
  it("marks new, checked-off, reopened and removed items, and counts what is done", () => {
    const old = "# Build\n- [ ] Load data\n- [ ] Draw charts\n- [x] Pick colours\n- [ ] Old idea";
    const now = "# Build\n- [x] Load data\n- [ ] Draw charts\n- [ ] Pick colours\n  - [ ] Add a filter\n\n```\n- [ ] not an item\n```";
    const c = todoChange(old, now);
    expect(c.items.map((i) => `${i.text}:${i.change}`)).toEqual(["Load data:checked", "Draw charts:same", "Pick colours:reopened", "Add a filter:new"]);
    expect(c.items[3].depth).toBe(1);
    expect(c.items[0].section).toBe("Build");
    expect(c.removed).toEqual(["Old idea"]);
    expect([c.done, c.total]).toEqual([1, 4]);
  });
});
