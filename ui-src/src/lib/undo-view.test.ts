import { describe, expect, it } from "vitest";
import type { Preview, UndoChange } from "./api";
import { canOpenUndoFile, undoTitle, undoTotals } from "./undo-view";

const preview = {} as Preview;

describe("the undo card", () => {
  it("titles itself with the text before the file list", () => {
    expect(undoTitle("Undid the last change set: a.js, b.css")).toBe("Undid the last change set");
    expect(undoTitle("Nothing to undo")).toBe("Nothing to undo");
  });

  it("adds up the lines over all files, a file without counts as none", () => {
    const changes: UndoChange[] = [{ path: "a", added: 3, removed: 1 }, { path: "b", removed: 4 }, { path: "c", binary: true }];
    expect(undoTotals(changes)).toEqual({ added: 3, removed: 5 });
    expect(undoTotals([])).toEqual({ added: 0, removed: 0 });
  });

  it("opens a diff only for a text file with a preview", () => {
    expect(canOpenUndoFile({ path: "a", preview })).toBe(true);
    expect(canOpenUndoFile({ path: "a", preview, binary: true })).toBe(false);
    expect(canOpenUndoFile({ path: "a", preview: null })).toBe(false);
    expect(canOpenUndoFile({ path: "a" })).toBe(false);
  });
});
