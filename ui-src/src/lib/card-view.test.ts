import { describe, expect, it } from "vitest";
import { startsOpen } from "./card-view";

describe("startsOpen", () => {
  it("opens change cards when the view is expanded", () => {
    expect(startsOpen("edit", "expanded")).toBe(true);
    expect(startsOpen("write", "expanded")).toBe(true);
  });
  it("keeps other cards and every card under collapsed closed", () => {
    expect(startsOpen("read", "expanded")).toBe(false);
    expect(startsOpen("run", "expanded")).toBe(false);
    expect(startsOpen("edit", "collapsed")).toBe(false);
  });
});
