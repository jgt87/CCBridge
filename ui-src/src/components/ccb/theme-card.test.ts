import { describe, expect, it } from "vitest";
import { isHexColour, normalizeHex, themeAdjustedText, themeAppliedText, themeInputProblem, themeRequest, themeSwatches } from "./theme-card-view";

describe("theme card", () => {
  it("reads colours as people write them", () => {
    expect(normalizeHex("#ABC")).toBe("#aabbcc");
    expect(normalizeHex(" 10069F ")).toBe("#10069f");
    expect(normalizeHex("blue")).toBe("blue");
    expect(isHexColour("abc")).toBe(true);
    expect(isHexColour("#12345")).toBe(false);
  });

  it("asks for an accent and refuses what is not a colour", () => {
    expect(themeInputProblem({ accent: "", accent2: "", neutral: "" })).toBe("Choose an accent colour.");
    expect(themeInputProblem({ accent: "red", accent2: "", neutral: "" })).toMatch(/accent is not a colour/);
    expect(themeInputProblem({ accent: "#10069f", accent2: "x", neutral: "" })).toMatch(/second colour/);
    expect(themeInputProblem({ accent: "#10069f", accent2: "", neutral: "#zzz" })).toMatch(/neutral tint/);
    expect(themeInputProblem({ accent: "#10069f", accent2: "", neutral: "" })).toBe("");
  });

  it("sends normalised colours and leaves empty ones empty", () => {
    expect(themeRequest({ accent: "ABC", accent2: " ", neutral: "#6B7280" })).toEqual({ accent: "#aabbcc", accent2: "", neutral: "#6b7280" });
  });

  it("shows the accent family and the chart colours that came back", () => {
    const sw = themeSwatches({ "--kit-accent": "#111111", "--kit-accent-hover": "#000000", "--kit-chart-1": "#ff0000", "--kit-chart-2": "#00ff00", "--kit-bg": "#ffffff" });
    expect(sw.accent.map((s) => s.label)).toEqual(["Accent", "Hover"]);
    expect(sw.charts.map((s) => s.value)).toEqual(["#ff0000", "#00ff00"]);
    expect(themeSwatches(undefined)).toEqual({ accent: [], charts: [] });
  });

  it("says what was adjusted and what Apply does", () => {
    expect(themeAdjustedText({ adjusted: [] })).toMatch(/reads as given/);
    expect(themeAdjustedText({ adjusted: ["accent darkened", "band darkened"] })).toBe("Adjusted so text stays readable: accent darkened; band darkened.");
    expect(themeAppliedText("t1")).toMatch(/Undo brings the old colours back/);
  });
});
