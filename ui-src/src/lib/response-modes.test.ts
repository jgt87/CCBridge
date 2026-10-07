import { describe, expect, it } from "vitest";
import { responseChoices } from "./response-modes";

describe("response picker choices", () => {
  it("adds the options Copilot offers beyond the classic three", () => {
    const c = responseChoices([
      { path: "Auto", title: "Auto", description: "Decides how long to think" },
      { path: "Think deeper", title: "Think deeper" },
      { path: "Advanced reasoning (Experimental)", title: "Advanced reasoning (Experimental)", description: "Performs complex tasks" },
      { path: "GPT > GPT-6.1 Sol", title: "GPT-6.1 Sol", parent: "GPT" },
    ]);
    expect(c.map((x) => x.value)).toEqual(["leave", "auto", "quick", "deep", "pick:Advanced reasoning (Experimental)", "pick:GPT > GPT-6.1 Sol"]);
    expect(c[5].label).toBe("Response: GPT-6.1 Sol (GPT)");
    expect(c[4].hint).toBe("Performs complex tasks");
  });
  it("keeps the current choice before the options are known", () => {
    const c = responseChoices(null, "pick:GPT > GPT-6.1 Sol");
    expect(c[c.length - 1]).toEqual({ value: "pick:GPT > GPT-6.1 Sol", label: "Response: GPT > GPT-6.1 Sol" });
    expect(responseChoices(undefined, "deep")).toHaveLength(4);
  });
});
