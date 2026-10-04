/** What StreamHub does not do (yet), shown on the start screen once Copilot is connected. */
export interface Limitation {
  title: string;
  detail: string;
}

export const LIMITATIONS: Limitation[] = [
  { title: "No Git integration", detail: "StreamHub has no Git features: it does not commit, branch or push. Use your own Git tools for that." },
  { title: "No MCP support", detail: "MCP servers cannot be connected to StreamHub, so their tools are not available in a task." },
  { title: "No skill support", detail: "No reusable skill packages; project notes (AGENTS.md) and runbooks carry instructions." },
  { title: "No artefact generator", detail: "No generated documents, slides or images; Copilot writes text and code files." },
];
