import { describe, expect, it } from "vitest";
import { findAppEntry } from "./app-entry";

describe("findAppEntry", () => {
  it("prefers a build's output over the root page", () => {
    expect(findAppEntry(["index.html", "src/main.tsx", "dist/index.html", "dist/assets/a.js"])).toBe("dist/index.html");
    expect(findAppEntry(["Build/index.html"])).toBe("build/index.html");
    expect(findAppEntry(["index.html", "styles.css"])).toBe("index.html");
  });
  it("finds nothing for projects without a page", () => {
    expect(findAppEntry(["src/app.ps1", "docs/index.html"])).toBeNull();
    expect(findAppEntry([])).toBeNull();
  });
});
