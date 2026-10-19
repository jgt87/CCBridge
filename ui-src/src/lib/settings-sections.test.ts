import { describe, expect, it } from "vitest";
import { currentSection, settingGroups, settingSections } from "./settings-sections";

const s = (key: string, group: string) => ({ key, group });

describe("settings sections", () => {
  it("groups settings in their first order, without Sign-in settings", () => {
    const groups = settingGroups([s("a", "Timing"), s("b", "App"), s("c", "Timing"), s("d", "Sign-in")]);
    expect(groups.map(([g, list]) => [g, list.map((x) => x.key)])).toEqual([
      ["Timing", ["a", "c"]],
      ["App", ["b"]],
    ]);
  });

  it("puts App first, then the fixed sections, then the other groups", () => {
    expect(settingSections(["Timing", "App", "Copilot"])).toEqual(["App", "This browser", "This computer", "Sign-in", "Timing", "Copilot"]);
    expect(settingSections(["Timing"])).toEqual(["This browser", "This computer", "Sign-in", "Timing"]);
  });

  it("falls back to the first section for a stored name that is gone", () => {
    const sections = ["App", "This browser"];
    expect(currentSection(sections, "This browser")).toBe("This browser");
    expect(currentSection(sections, "Removed group")).toBe("App");
  });
});
