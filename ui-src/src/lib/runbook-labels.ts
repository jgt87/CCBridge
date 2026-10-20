/** The texts on a runbook's row in Automation > Runbooks: its kind, when it last ran, and its buttons' titles. */

type Kind = "text" | "json";

/** The badge after the title: JSON checked against the runbook's shape, or the answer as Markdown. */
export function kindBadge(kind: Kind): { text: string; title: string } {
  return kind === "json" ? { text: "JSON", title: "Saves JSON checked against the runbook's shape" } : { text: "text", title: "Saves Copilot's answer as Markdown" };
}

/** "run 5 min ago" from the fetch panel's age text, or "never run". */
export function lastRunLabel(lastRun: string | null, age: (iso: string) => string): string {
  return lastRun ? age(lastRun).replace("fetched", "run") : "never run";
}

/** The Run button: straight away, or into the queue while a task runs. */
export function runTitle(busy: boolean): string {
  return busy ? "Add it to the queue; the result is saved when it runs" : "Run it now in a fresh Copilot chat and save the result";
}

/** Result and Attach need a result: until the first run they are off and say so. */
export function resultTitle(lastRun: string | null, output: string): string {
  return lastRun ? `View the latest result (${output})` : "Not run yet";
}

export function attachTitle(lastRun: string | null, output: string): string {
  return lastRun ? `Attach @${output} to your message` : "Not run yet";
}
