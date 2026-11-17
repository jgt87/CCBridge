// The bar for a chat Copilot was left running in at the time cap (state.pendingChat): StreamHub
// stopped waiting without pressing Stop, so Copilot's work goes on and its answer can be read later.

/** The local time the request was sent ("10:42"), from the server's local ISO time; "" when unreadable. */
export function pendingSince(since: string | null | undefined): string {
  const m = /T(\d{2}):(\d{2})/.exec(since ?? "");
  return m ? `${m[1]}:${m[2]}` : "";
}

/** The bar's sentence. */
export function pendingChatText(since: string | null | undefined): string {
  const at = pendingSince(since);
  return `Copilot was still working when StreamHub stopped waiting${at ? ` (request sent at ${at})` : ""}. It was left running, so its work is not lost.`;
}
