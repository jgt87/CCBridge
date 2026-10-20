import { describe, expect, it } from "vitest";
import type { ProjectInfo } from "@/lib/api";
import { type ProjectList, projectRowStatus, projectsWatch } from "./projects-watch";

const project = (path: string, modified: string) => ({ name: path, path, modified }) as ProjectInfo;
const list = (...projects: ProjectInfo[]): ProjectList => ({ root: "C:/OneDrive/CCBridge", projects });

/** A source whose lists the test sets, counting the calls. */
function fakeSource(start: ProjectList) {
  const s = {
    fullList: start,
    quickList: start,
    fullCalls: 0,
    quickCalls: 0,
    hidden: false,
    quickFails: false,
    fullFails: false,
    shown: [] as ProjectList[],
    errors: [] as string[],
  };
  const src = {
    full: async () => {
      s.fullCalls++;
      if (s.fullFails) throw new Error("no server");
      return s.fullList;
    },
    quick: async () => {
      s.quickCalls++;
      if (s.quickFails) throw new Error("no server");
      return s.quickList;
    },
    show: (l: ProjectList) => s.shown.push(l),
    fail: (m: string) => s.errors.push(m),
    hidden: () => s.hidden,
  };
  return { s, src };
}

describe("projectsWatch", () => {
  it("loads the full list again only when names or times changed", async () => {
    const { s, src } = fakeSource(list(project("a", "2026-10-01T10:00")));
    const w = projectsWatch(src);
    await w.start();
    expect(s.shown).toHaveLength(1);
    await w.check();
    expect(s.quickCalls).toBe(1);
    expect(s.fullCalls).toBe(1);
    s.quickList = list(project("a", "2026-10-01T10:00"), project("b", "2026-10-02T09:00"));
    s.fullList = s.quickList;
    await w.check();
    expect(s.fullCalls).toBe(2);
    expect(s.shown[1].projects.map((p) => p.path)).toEqual(["a", "b"]);
  });

  it("does not check while hidden, while a load runs, or after stop", async () => {
    const { s, src } = fakeSource(list(project("a", "t1")));
    const w = projectsWatch(src);
    const first = w.start();
    await w.check(); // the first load still runs
    expect(s.quickCalls).toBe(0);
    await first;
    s.hidden = true;
    await w.check();
    expect(s.quickCalls).toBe(0);
    s.hidden = false;
    w.stop();
    await w.check();
    expect(s.quickCalls).toBe(0);
  });

  it("shows nothing that arrives after stop", async () => {
    const { s, src } = fakeSource(list(project("a", "t1")));
    const w = projectsWatch(src);
    const first = w.start();
    w.stop();
    await first;
    expect(s.shown).toHaveLength(0);
  });

  it("reports a failed full load, and a failed quick look waits for the next check", async () => {
    const { s, src } = fakeSource(list(project("a", "t1")));
    s.fullFails = true;
    const w = projectsWatch(src);
    await w.start();
    expect(s.errors).toEqual(["no server"]);
    s.fullFails = false;
    s.quickFails = true;
    await w.check();
    expect(s.errors).toEqual(["no server"]);
    s.quickFails = false;
    await w.check(); // nothing shown yet, so the signature differs: the full list loads
    expect(s.shown).toHaveLength(1);
  });

  it("the Refresh load reads the full list whatever the quick look says", async () => {
    const { s, src } = fakeSource(list(project("a", "t1")));
    const w = projectsWatch(src);
    await w.start();
    await w.load();
    expect(s.fullCalls).toBe(2);
    expect(s.shown).toHaveLength(2);
  });
});

describe("projectRowStatus", () => {
  it("says Opening... on the row being opened, else when it changed", () => {
    const p = { path: "C:/p/a", modified: "2026-10-01T10:00:00" };
    expect(projectRowStatus(p, "C:/p/a")).toBe("Opening...");
    expect(projectRowStatus(p, "C:/p/b")).toBe("changed 2026-10-01 10:00:00");
    expect(projectRowStatus(p, "")).toBe("changed 2026-10-01 10:00:00");
  });
});
