import { describe, expect, it } from "vitest";
import { cardExpanded, cardOpen } from "./card-view";

describe("cardExpanded", () => {
  it("always shows a card that awaits approval, even after the reader closed it", () => {
    expect(cardExpanded(true, false, false, "ok", "auto-collapse")).toBe(true);
  });
  it("follows the reader's own open or close over the setting and a running command", () => {
    expect(cardExpanded(false, false, true, "running", "expanded")).toBe(false);
    expect(cardExpanded(false, true, false, "ok", "auto-collapse")).toBe(true);
  });
  it("otherwise opens while its command runs, else by the setting", () => {
    expect(cardExpanded(false, null, true, "ok", "auto-collapse")).toBe(true);
    expect(cardExpanded(false, null, false, "ok", "auto-collapse")).toBe(false);
    expect(cardExpanded(false, null, false, "failed", "auto-collapse")).toBe(true);
    expect(cardExpanded(false, null, false, "ok", "expanded")).toBe(true);
  });
});

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
