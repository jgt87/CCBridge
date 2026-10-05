/** What the index line says: an index run is busy, nothing was indexed yet, indexed without issues, or with issues. */
export type IndexState = "busy" | "never" | "clean" | "issues";

export function indexState(running: boolean, files: number, withIssues: number): IndexState {
  if (running) return "busy";
  if (!files) return "never";
  return withIssues ? "issues" : "clean";
}
