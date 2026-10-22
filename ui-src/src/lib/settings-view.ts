import type { ResponseOption } from "./response-modes";

/** The help line of Settings > Copilot > response options: when the picker was read and what it offers. */
export function responseOptionsHelp(read: string, options: ResponseOption[]): string {
  const when = read ? new Date(read).toLocaleString() : "never";
  const offered = options.map((o) => (o.parent ? `${o.title} (${o.parent})` : o.title)).join(", ");
  return `Opens Copilot's response picker and reads what it offers, for the Response menu next to New chat. Last read: ${when}.${
    options.length ? ` Offered: ${offered}.` : ""
  }`;
}

/** The note after "Reset all to defaults": the settings plus the theme that were set back. */
export function resetNoteText(changed: number, themeReset: boolean): string {
  const n = changed + (themeReset ? 1 : 0);
  return n ? `${n} setting(s) set back to the app defaults.` : "All settings already had the app defaults.";
}
