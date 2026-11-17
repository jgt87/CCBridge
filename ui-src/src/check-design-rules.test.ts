// scripts/check-design-rules.mjs proves its own rules: --self-test opens a page that breaks every
// rule and one that keeps them, in headless Edge or Chrome, and fails unless each rule fails on the
// first and none on the second. This runs that proof with the tests; without a browser it is skipped.
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
// Imported as text so code-health tools pair this test with the script; it runs as its own process.
import script from "../scripts/check-design-rules.mjs?raw";

const scriptPath = path.resolve(import.meta.dirname, "../scripts/check-design-rules.mjs");
// The browsers the script itself looks for (its BROWSERS list).
const browser = [
  process.env.CHROME_PATH,
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
  "/usr/bin/microsoft-edge",
].find((p) => p && existsSync(p));

describe("check-design-rules.mjs", () => {
  it("is the script with a self-test", () => {
    expect(script).toContain("--self-test");
  });
  it.skipIf(!browser)("fails every rule on a broken page and none on a kept one (--self-test)", () => {
    // Its own debug port, apart from the design checks' (9571) and the defaults other projects use.
    const run = spawnSync(process.execPath, [scriptPath, "--self-test", "--port", "9585"], { encoding: "utf8", timeout: 150_000 });
    expect(run.status, run.stdout + run.stderr).toBe(0);
    expect(run.stdout).toMatch(/^OK: the broken page failed all \d+ rules/m);
  }, 180_000);
});
