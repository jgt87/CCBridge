import type { ToolItem } from "@/lib/api";

/** Where the Node.js install the packages card started stands ("" = not started). */
export type NodeInstall = "" | "installing" | "pending" | "done" | "failed";

/** What one look at the tools list means for a Node.js install that is running: null while it still runs. */
export function nodeInstallUpdate(tools: ToolItem[]): { node: Exclude<NodeInstall, "" | "installing">; message: string } | null {
  const n = tools.find((t) => t.name === "node");
  const s = n?.install?.state;
  if (s === "done") return { node: "done", message: "" };
  if (s === "failed" || s === "pending") return { node: s, message: n?.install?.message ?? "" };
  return null;
}

/** The status lines under the packages card's question, in order; `error` lines show in the error colour. */
export function packagesNotes(npm: boolean, node: NodeInstall, nodeMessage: string, installFailed: boolean): { text: string; error: boolean }[] {
  const notes: { text: string; error: boolean }[] = [];
  const note = (text: string) => notes.push({ text, error: false });
  if (!npm && node === "") note("npm is not installed. Node.js brings it: an install for this user only, from nodejs.org (nothing needs admin rights).");
  if (node === "installing") note("Installing Node.js in the background...");
  if (node === "pending") note(`Node.js is in use; it is installed at the next start of StreamHub. ${nodeMessage}`);
  if (node === "done") note("Node.js and npm are installed.");
  if (node === "failed") notes.push({ text: `Node.js could not be installed. ${nodeMessage}`, error: true });
  if (installFailed) notes.push({ text: "npm install could not be started.", error: true });
  return notes;
}
