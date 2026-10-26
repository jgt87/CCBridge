/** The card after an answer-only task refused Copilot's edits (event edits-refused). */
export interface EditsRefusedItem {
  kind: "editsRefused";
  seq: number;
  replayId: string;
  count: number;
  files: string[];
  request: string;
  restored: boolean;
}

/** The card's main line: how many edits, to which files. */
export function editsRefusedText(count: number, files: string[]): string {
  const what = count === 1 ? "1 edit" : `${count} edits`;
  const where = files.length ? ` to ${files.join(", ")}` : "";
  return `Copilot wrote ${what}${where}, but StreamHub handled your message as a question, so nothing was changed.`;
}
