import { describe, expect, it } from "vitest";
import { fillClassOf, gridColumns, slideDirection, spareColumns } from "./smooth-tab";

describe("smooth tab layout", () => {
  it("puts the tabs in one row unless columns are given, within 1 and the number of tabs", () => {
    expect(gridColumns(undefined, 4)).toBe(4);
    expect(gridColumns(2, 4)).toBe(2);
    expect(gridColumns(6, 4)).toBe(4);
    expect(gridColumns(0, 4)).toBe(1);
    expect(gridColumns(undefined, 0)).toBe(1);
  });

  it("lets only the last tab span the columns its row leaves free", () => {
    // 5 tabs in 2 columns: the last one is alone on its row and spans one more column.
    expect([0, 1, 2, 3, 4].map((i) => spareColumns(i, 5, 2))).toEqual([0, 0, 0, 0, 1]);
    // 4 tabs in 3 columns: the last row has one tab, two columns free.
    expect(spareColumns(3, 4, 3)).toBe(2);
    // A full last row leaves nothing.
    expect(spareColumns(3, 4, 2)).toBe(0);
    expect(spareColumns(3, 4, 4)).toBe(0);
  });

  it("slides forward to a later tab and back otherwise", () => {
    const ids = ["a", "b", "c"];
    expect(slideDirection(ids, "a", "c")).toBe(1);
    expect(slideDirection(ids, "c", "a")).toBe(-1);
    expect(slideDirection(ids, "b", "b")).toBe(-1);
  });

  it("takes the card colour from the first colour class", () => {
    expect(fillClassOf("bg-blue-500 hover:bg-blue-600")).toBe("blue-500");
    expect(fillClassOf("")).toBe("");
  });
});
