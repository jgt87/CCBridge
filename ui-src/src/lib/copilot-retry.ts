/**
 * What the header offers while Copilot is not connected (Server copilotRetryAt): StreamHub still
 * tries again by itself at a time ("tries again at 10:42", with a small Retry), or it stopped trying
 * after a while and the person checks the connection with a button.
 */
export type CopilotRetry = { kind: "none" } | { kind: "auto"; at: string } | { kind: "stopped" };

export function copilotRetry(copilot: string, retryAt: string | undefined): CopilotRetry {
  if (copilot !== "error") return { kind: "none" };
  if (!retryAt) return { kind: "stopped" };
  const d = new Date(retryAt);
  if (Number.isNaN(d.getTime())) return { kind: "stopped" };
  const pad = (n: number) => String(n).padStart(2, "0");
  return { kind: "auto", at: `${pad(d.getHours())}:${pad(d.getMinutes())}` };
}
