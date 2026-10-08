import { describe, expect, it } from "vitest";
import { formatBytes, overviewText, projectsSignature } from "./project-overview";

describe("project overview", () => {
  it("formats sizes", () => {
    expect(formatBytes(950)).toBe("950 B");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(12 * 1024 * 1024)).toBe("12 MB");
  });
  it("shows size and type in one line", () => {
    expect(overviewText({ files: 42, bytes: 1258291, languages: ["HTML", "JavaScript", "CSS"], sourceFiles: 2, capped: false })).toBe(
      "42 files · 1.2 MB · HTML, JavaScript, CSS · source data",
    );
    expect(overviewText({ files: 1, bytes: 10, languages: [], sourceFiles: 0, capped: false })).toBe("1 file · 10 B");
    expect(overviewText({ files: 0, bytes: 0, languages: [], sourceFiles: 0, capped: false })).toBe("empty");
    expect(overviewText(null)).toBe("");
  });
});

describe("projectsSignature", () => {
  it("changes when a folder is added or changed, not when only the order differs", () => {
    const a = { path: "C:\OD\P\one", modified: "2026-10-08T10:00:00" };
    const b = { path: "C:\OD\P\two", modified: "2026-10-08T11:00:00" };
    expect(projectsSignature([a, b])).toBe(projectsSignature([b, a]));
    expect(projectsSignature([a])).not.toBe(projectsSignature([a, b]));
    expect(projectsSignature([a, b])).not.toBe(projectsSignature([a, { ...b, modified: "2026-10-08T11:05:00" }]));
    expect(projectsSignature(null)).toBe("");
  });
});
