// Texts and checks of the theme card (components/ccb/theme-card.tsx). The colours themselves are
// derived by StreamHub (lib/KitTheme.psm1, through /api/kit-theme/preview), never here.
import type { ThemeColours, ThemePreview } from "@/lib/api";

/** "#abc", "abc" or "#AABBCC" as "#aabbcc"; anything else unchanged (trimmed). */
export function normalizeHex(value: string): string {
  const v = value.trim().toLowerCase();
  const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/.exec(v);
  if (!m) return v;
  const h = m[1];
  return `#${h.length === 3 ? [...h].map((c) => c + c).join("") : h}`;
}

export const isHexColour = (value: string) => /^#[0-9a-f]{6}$/.test(normalizeHex(value));

/** What keeps the colours from being previewed: "" when they can be. */
export function themeInputProblem(c: ThemeColours): string {
  if (!c.accent.trim()) return "Choose an accent colour.";
  if (!isHexColour(c.accent)) return "The accent is not a colour: write it as #rrggbb.";
  if (c.accent2.trim() && !isHexColour(c.accent2)) return "The second colour is not a colour: write it as #rrggbb, or leave it empty.";
  if (c.neutral.trim() && !isHexColour(c.neutral)) return "The neutral tint is not a colour: write it as #rrggbb, or leave it empty.";
  return "";
}

/** The colours as sent to StreamHub: normalised, empty ones left empty. */
export function themeRequest(c: ThemeColours): ThemeColours {
  const n = (v: string) => (v.trim() ? normalizeHex(v) : "");
  return { accent: n(c.accent), accent2: n(c.accent2), neutral: n(c.neutral) };
}

export type Swatch = { token: string; label: string; value: string };

const SWATCHES: [string, string][] = [
  ["--kit-accent", "Accent"],
  ["--kit-accent-hover", "Hover"],
  ["--kit-accent-soft", "Badge"],
  ["--kit-accent-2", "Second"],
];

/** The swatches of one mode: the accent family, then the six chart colours. */
export function themeSwatches(tokens: Record<string, string> | undefined): { accent: Swatch[]; charts: Swatch[] } {
  const t = tokens ?? {};
  const accent = SWATCHES.filter(([k]) => t[k]).map(([token, label]) => ({ token, label, value: t[token] }));
  const charts = [1, 2, 3, 4, 5, 6].filter((i) => t[`--kit-chart-${i}`]).map((i) => ({ token: `--kit-chart-${i}`, label: `Chart ${i}`, value: t[`--kit-chart-${i}`] }));
  return { accent, charts };
}

/** The line under the preview: what was adjusted to read, or that nothing had to be. */
export function themeAdjustedText(p: Pick<ThemePreview, "adjusted">): string {
  return p.adjusted.length ? `Adjusted so text stays readable: ${p.adjusted.join("; ")}.` : "Every colour reads as given (WCAG AA).";
}

/** What the card says once Apply is queued. */
export function themeAppliedText(queued: string | null): string {
  return queued ? "Applying: the change shows in the chat, and Undo brings the old colours back." : "Nothing to apply.";
}
