import { describe, expect, it, vi } from "vitest";
import { resetNoteText, responseOptionsHelp } from "./settings-view";

describe("settings view", () => {
  it("says the picker was never read and lists nothing without options", () => {
    const text = responseOptionsHelp("", []);
    expect(text).toContain("Last read: never.");
    expect(text).not.toContain("Offered");
  });

  it("lists the offered options with their parent menu", () => {
    // The machine's locale and time zone pinned, so the date format is checked, not copied from the same call.
    const toLocale = Date.prototype.toLocaleString;
    const spy = vi.spyOn(Date.prototype, "toLocaleString").mockImplementation(function (this: Date) {
      return toLocale.call(this, "en-GB", { timeZone: "UTC" });
    });
    const text = responseOptionsHelp("2026-10-01T10:00:00Z", [
      { path: "Quick", title: "Quick" },
      { path: "GPT > Model", title: "Model", parent: "GPT" },
    ]);
    spy.mockRestore();
    expect(text).toContain("Last read: 01/10/2026, 10:00:00.");
    expect(text).toMatch(/Offered: Quick, Model \(GPT\)\.$/);
  });

  it("counts the theme with the reset settings", () => {
    expect(resetNoteText(2, true)).toBe("3 setting(s) set back to the app defaults.");
    expect(resetNoteText(0, true)).toBe("1 setting(s) set back to the app defaults.");
    expect(resetNoteText(0, false)).toBe("All settings already had the app defaults.");
  });
});
