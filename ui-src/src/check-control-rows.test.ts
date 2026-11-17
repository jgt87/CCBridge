// scripts/check-control-rows.mjs proves its own scan: --self-test opens a row of controls with mixed
// heights and one with a single height, in headless Edge or Chrome, and fails unless it catches the
// first and passes the second. This runs that proof with the tests; without a browser it is skipped.
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
// Imported as text so code-health tools pair this test with the script; it runs as its own process.
import script from "../scripts/check-control-rows.mjs?raw";

const scriptPath = path.resolve(import.meta.dirname, "../scripts/check-control-rows.mjs");
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

describe("check-control-rows.mjs", () => {
  it("is the script with a self-test", () => {
    expect(script).toContain("--self-test");
  });
  it.skipIf(!browser)("catches a row of mixed heights and passes a row of one height (--self-test)", () => {
    // Its own debug port, apart from the design checks' (9572) and the defaults other projects use.
    const run = spawnSync(process.execPath, [scriptPath, "--self-test", "--port", "9586"], { encoding: "utf8", timeout: 150_000 });
    expect(run.status, run.stdout + run.stderr).toBe(0);
    expect(run.stdout).toMatch(/^OK: the scan caught the mixed row and passed the fixed one/m);
  }, 180_000);
});
