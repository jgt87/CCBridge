import { describe, expect, it } from "vitest";
import { cardOpen } from "./card-view";

describe("cardOpen", () => {
  it("opens every card when the view is expanded (the default)", () => {
    for (const s of ["ok", "running", "failed", "already applied", "rejected"]) expect(cardOpen(s, "expanded")).toBe(true);
  });
  it("folds finished cards under auto-collapse and keeps what needs the reader open", () => {
    expect(cardOpen("ok", "auto-collapse")).toBe(false);
    expect(cardOpen("already applied", "auto-collapse")).toBe(false);
    expect(cardOpen("rejected", "auto-collapse")).toBe(false);
    expect(cardOpen("running", "auto-collapse")).toBe(true);
    expect(cardOpen("awaiting", "auto-collapse")).toBe(true);
    expect(cardOpen("failed", "auto-collapse")).toBe(true);
  });
});
