import { describe, expect, it } from "vitest";
import type { WorkStatus } from "@/lib/api";
import { isNewQuietSpell, tabTitle, workView } from "./work-status";

const base = new Date(2026, 9, 19, 12, 0, 0).getTime();
const iso = (secondsAfter: number) => {
  const d = new Date(base + secondsAfter * 1000);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
};
const work = (over: Partial<WorkStatus> = {}): WorkStatus => ({
  kind: "chat",
  startedAt: iso(0),
  phase: "Waiting for Copilot's reply",
  phaseAt: iso(270),
  lastSignAt: iso(395),
  lastDataAt: iso(395),
  round: 3,
  actions: 4,
  changed: 2,
  waitSec: 1800,
  stallSec: 90,
  steps: [{ at: iso(10), text: "Sent a message to Copilot" }],
  ...over,
});

describe("workView", () => {
  it("says what happens now, for how long, and where the task is", () => {
    const v = workView(work(), base + 400_000);
    expect(v.phase).toBe("Waiting for Copilot's reply · 2 min 10 s");
    expect(v.detail).toBe("Task 6 min 40 s · round 3 · 4 actions · 2 files changed");
    expect(v.sign).toBe("Copilot wrote 5 s ago");
    expect(v.quiet).toBe(false);
    expect(v.steps).toHaveLength(1);
  });
  it("warns after three minutes without any sign, with how long StreamHub waits", () => {
    const v = workView(work({ lastSignAt: iso(100), lastDataAt: "" }), base + 400_000);
    expect(v.quiet).toBe(true);
    expect(v.sign).toBe("updated 5 min ago");
    expect(v.quietText).toMatch(/up to 30 min in all; with no sign at all it stops after 1 min 30 s/);
    expect(workView(work({ lastSignAt: iso(100), waitSec: 0 }), base + 400_000).quietText).toMatch(/still on this step/);
  });
  it("accepts one step sent as a single object (PowerShell's JSON)", () => {
    expect(workView(work({ steps: { at: iso(1), text: "One" } }), base + 400_000).steps).toHaveLength(1);
  });
});

describe("tabTitle", () => {
  it("shows the phase and minutes while busy, a warning sign when quiet, and the name otherwise", () => {
    expect(tabTitle(true, work(), base + 400_000)).toBe("⏳ Waiting for Copilot's reply · 6 min – StreamHub");
    expect(tabTitle(true, work({ lastSignAt: iso(0) }), base + 400_000)).toMatch(/^⚠ /);
    expect(tabTitle(false, work(), base)).toBe("StreamHub");
  });
});

describe("isNewQuietSpell", () => {
  it("notifies once per quiet spell, only while busy", () => {
    const quiet = work({ lastSignAt: iso(0) });
    expect(isNewQuietSpell(true, quiet, "", base + 400_000)).toBe(true);
    expect(isNewQuietSpell(true, quiet, quiet.lastSignAt, base + 400_000)).toBe(false);
    expect(isNewQuietSpell(false, quiet, "", base + 400_000)).toBe(false);
    expect(isNewQuietSpell(true, null, "", base + 400_000)).toBe(false);
    expect(isNewQuietSpell(true, work(), "", base + 400_000)).toBe(false);
  });
});
