// Texts and data of the "Build a deck from an outline" card (pptx-outline-card.tsx) and of the cards for a
// file Copilot made in its own workspace (sandbox-card.tsx). What is built and fetched is decided by
// StreamHub (lib/PptxDeck.psm1, lib/Download.psm1); the cards only let the person choose and press.

function list<T>(v: unknown): T[] {
  // Windows PowerShell 5.1 sends a one-item list as the item itself.
  return Array.isArray(v) ? (v as T[]) : v === null || v === undefined || v === "" ? [] : [v as T];
}

/** The pptx-outline event: the project's deck outlines and templates, one of each chosen to start with. */
export interface PptxOutlineItem {
  kind: "pptxOutline";
  seq: number;
  text: string;
  outlines: string[];
  templates: string[];
  outline: string;
  template: string;
  restored: boolean;
}

export function pptxOutlineItem(e: { seq: number; restored?: boolean; text?: string; pptx?: unknown }): PptxOutlineItem {
  const r = (e.pptx ?? {}) as Record<string, unknown>;
  const outlines = list<string>(r.outlines).map(String);
  const templates = list<string>(r.templates).map(String);
  const outline = String(r.outline ?? "") || outlines[0] || "";
  const template = String(r.template ?? "") || templates.find((t) => /\.potx$/i.test(t) || /template|sjabloon|huisstijl|brand/i.test(t)) || templates[0] || "";
  return { kind: "pptxOutline", seq: e.seq, text: e.text ?? "", outlines, templates, outline, template, restored: Boolean(e.restored) };
}

/** Why Build cannot start yet, or "" when it can. */
export function buildProblem(outline: string, template: string): string {
  if (!outline) return "Choose a deck outline.";
  if (!/\.deck\.json$/i.test(outline)) return "A deck outline is a .deck.json file.";
  if (!template) return "Choose a template (a .pptx or .potx in the project).";
  return "";
}

/** The sandbox-fetch event: the file asked for, the links in Copilot's answer, whether it asked for a confirmation. */
export interface SandboxFetchItem {
  kind: "sandboxFetch";
  seq: number;
  file: string;
  links: string[];
  human: boolean;
  restored: boolean;
}

export function sandboxFetchItem(e: { seq: number; restored?: boolean; file?: string; links?: unknown; human?: boolean }): SandboxFetchItem {
  return { kind: "sandboxFetch", seq: e.seq, file: e.file ?? "", links: list<string>(e.links).map(String), human: e.human === true, restored: Boolean(e.restored) };
}

/** A link in plain words: its host and file name. */
export function linkLabel(url: string): string {
  try {
    const u = new URL(url);
    const last = decodeURIComponent(u.pathname.split("/").filter(Boolean).pop() ?? "");
    return last && /\.[A-Za-z0-9]{2,5}$/.test(last) ? `${last} on ${u.host}` : u.host;
  } catch {
    return url;
  }
}

/** The files an assistant reply names in Copilot's own workspace (as the event carries them). */
export function sandboxFiles(v: unknown): string[] {
  return list<string>(v).map(String).filter(Boolean);
}
