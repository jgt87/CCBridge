import { describe, expect, it } from "vitest";
import { openWhenFree, type ProjectOpenAnswer } from "./project-open";

const answers = (...list: ProjectOpenAnswer[]) => {
  let i = 0;
  return async () => list[Math.min(i++, list.length - 1)];
};
const noSleep = { sleep: async () => {} };

describe("openWhenFree", () => {
  it("tries again while the open project is being made ready, showing why, then opens", async () => {
    const waits: string[] = [];
    const prep = { ok: false, busy: "preparing" as const, retry: true, message: "Opening B as soon as StreamHub is still getting A ready." };
    const out = await openWhenFree(answers(prep, prep, { ok: true }), (m) => waits.push(m), () => false, noSleep);
    expect(out).toEqual({ status: "opened", path: undefined });
    expect(waits).toEqual([prep.message, prep.message]);
  });

  it("comes back at once when a task runs: that is the person's to finish or stop", async () => {
    const waits: string[] = [];
    const out = await openWhenFree(answers({ ok: false, busy: "task", retry: false, message: "A task is still running in A." }), (m) => waits.push(m), () => false, noSleep);
    expect(out).toEqual({ status: "waiting-task", message: "A task is still running in A." });
    expect(waits).toEqual([]);
  });

  it("stops waiting when cancelled, and gives up after the limit", async () => {
    const prep = { ok: false, retry: true, message: "Opening B as soon as..." };
    expect(await openWhenFree(answers(prep), () => {}, () => true, noSleep)).toEqual({ status: "cancelled" });
    const out = await openWhenFree(answers(prep), () => {}, () => false, { ...noSleep, maxMs: 0 });
    expect(out.status).toBe("gave-up");
  });
});
