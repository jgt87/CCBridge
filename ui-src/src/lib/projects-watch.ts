import type { ProjectInfo } from "@/lib/api";
import { projectsSignature } from "@/lib/project-overview";

export type ProjectList = { root: string; projects: ProjectInfo[] };

/** Where the picker's list comes from and goes to. */
export interface ProjectsWatchSource {
  /** The full list (folders, sizes and types). */
  full: () => Promise<ProjectList>;
  /** Names and times only, to notice a change cheaply. */
  quick: () => Promise<ProjectList>;
  show: (list: ProjectList) => void;
  fail: (message: string) => void;
  /** The page is not on screen: no checks then. */
  hidden: () => boolean;
}

/**
 * The project picker's list: `start` loads it once, `load` again (the Refresh button), and `check`
 * (on a timer, focus and visibility) takes a quick look at names and times and loads the full list
 * only when they changed, so a folder pasted into the projects folder (or one still being copied)
 * shows without reopening the picker. One load or check at a time; nothing is shown after `stop`.
 */
export function projectsWatch(src: ProjectsWatchSource) {
  let shown = "";
  let busy = false;
  let stopped = false;
  const load = () =>
    src.full().then((r) => {
      if (stopped) return;
      shown = projectsSignature(r.projects);
      src.show(r);
    }, (e) => src.fail(String((e as { message?: unknown }).message ?? e)));
  const check = async () => {
    if (busy || stopped || src.hidden()) return;
    busy = true;
    try {
      const r = await src.quick();
      if (!stopped && projectsSignature(r.projects) !== shown) await load();
    } catch {
      // the next check tries again
    } finally {
      busy = false;
    }
  };
  const start = () => {
    busy = true;
    return load().finally(() => {
      busy = false;
    });
  };
  const stop = () => {
    stopped = true;
  };
  return { start, load, check, stop };
}

/** The second line of a project's row: "Opening..." while it opens, else when it last changed. */
export function projectRowStatus(p: { path: string; modified: string }, opening: string): string {
  return opening === p.path ? "Opening..." : `changed ${p.modified.replace("T", " ")}`;
}
