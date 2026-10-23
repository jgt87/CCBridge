// When the Split screen hint (components/ccb/split-view-hint.tsx) shows: only in Edge, only when
// the app opened as a tab in the Copilot window (appWindow copilot-tab, the default), and only once.
export function splitHintEligible(userAgent: string, appWindow: string | undefined, shownBefore: boolean, seenHere: boolean): boolean {
  if (shownBefore || seenHere) return false;
  return /\bEdg\//.test(userAgent) && (appWindow ?? "copilot-tab") === "copilot-tab";
}
