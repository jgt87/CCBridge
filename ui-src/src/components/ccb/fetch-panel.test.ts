import { describe, expect, it } from "vitest";
import { webSummary } from "./fetch-panel";

describe("webSummary", () => {
  it("is empty for a runbook without header fields", () => {
    expect(webSummary({})).toBe("");
    expect(webSummary({ sources: "", sites: "  ", pages: "not a page", agent: "copilot", files: " , " })).toBe("");
  });

  it("names every header field in order", () => {
    expect(webSummary({ sources: "web", sites: " nodejs.org ", pages: "https://a.org", agent: " Analyst ", files: "a.csv, b.csv," })).toBe(
      "web only · nodejs.org · 1 page · Analyst · 2 files",
    );
    expect(webSummary({ sources: "work", pages: "https://a.org, http://b.org;ftp://c", agent: "researcher", files: "a.csv" })).toBe(
      "work data only · 2 pages · Researcher · 1 file",
    );
    expect(webSummary({ sources: "both" })).toBe("work data and web");
  });

  it("ignores unknown values, also ones that are names on every object", () => {
    expect(webSummary({ sources: "Web", agent: "toString" })).toBe("");
    expect(webSummary({ sources: "constructor" })).toBe("");
  });
});
