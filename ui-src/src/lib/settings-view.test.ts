import { describe, expect, it } from "vitest";
import { resetNoteText, responseOptionsHelp } from "./settings-view";

describe("settings view", () => {
  it("says the picker was never read and lists nothing without options", () => {
    const text = responseOptionsHelp("", []);
    expect(text).toContain("Last read: never.");
    expect(text).not.toContain("Offered");
  });

  it("lists the offered options with their parent menu", () => {
    const text = responseOptionsHelp("2026-10-01T10:00:00Z", [
      { path: "Quick", title: "Quick" },
      { path: "GPT > Model", title: "Model", parent: "GPT" },
    ]);
    expect(text).toContain(`Last read: ${new Date("2026-10-01T10:00:00Z").toLocaleString()}.`);
    expect(text).toMatch(/Offered: Quick, Model \(GPT\)\.$/);
  });

  it("counts the theme with the reset settings", () => {
    expect(resetNoteText(2, true)).toBe("3 setting(s) set back to the app defaults.");
    expect(resetNoteText(0, true)).toBe("1 setting(s) set back to the app defaults.");
    expect(resetNoteText(0, false)).toBe("All settings already had the app defaults.");
  });
});
