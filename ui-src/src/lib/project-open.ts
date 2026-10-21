/** What the server answers when a project cannot be opened right now (Server Get-ProjectSwitchBusy). */
export interface ProjectOpenAnswer {
  ok: boolean;
  /** "preparing": StreamHub is still getting the open project ready (ends by itself); "task": a task runs. */
  busy?: "preparing" | "task";
  retry?: boolean;
  message?: string;
  path?: string;
}

export type OpenOutcome = { status: "opened"; path?: string } | { status: "waiting-task"; message: string } | { status: "gave-up"; message: string } | { status: "cancelled" };

/**
 * Opens a project, trying again while StreamHub is still getting the open one ready (that ends by
 * itself): `onWait` gets the message to show meanwhile. A running task is the person's to finish or
 * stop, so that answer comes back at once. `cancelled()` ends the waiting (another project picked).
 */
export async function openWhenFree(
  attempt: () => Promise<ProjectOpenAnswer>,
  onWait: (message: string) => void,
  cancelled: () => boolean,
  { everyMs = 1500, maxMs = 180_000, sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms)) } = {},
): Promise<OpenOutcome> {
  const until = Date.now() + maxMs;
  for (;;) {
    const r = await attempt();
    if (r.ok) return { status: "opened", path: r.path };
    const message = r.message ?? "StreamHub cannot open the project right now.";
    if (!r.retry) return { status: "waiting-task", message };
    if (Date.now() >= until) return { status: "gave-up", message: `${message} This takes longer than usual: try again in a moment.` };
    onWait(message);
    await sleep(everyMs);
    if (cancelled()) return { status: "cancelled" };
  }
}
