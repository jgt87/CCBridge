// The previews of the template card's element choices: lib/PptxChoices.psm1 describes each option as a
// small drawing (a box in points with rectangles, rounded boxes, ellipses and text runs in the option's
// fonts, sizes and colours); these helpers turn that description into what pptx-drawing.tsx draws as SVG.

export interface DrawingRun {
  text: string;
  font: string;
  /** Points. */
  size: number;
  bold: boolean;
  /** RRGGBB, or "" for the default. */
  color: string;
}

export interface DrawingItem {
  type: "rect" | "roundRect" | "ellipse" | "text";
  x: number;
  y: number;
  w: number;
  h: number;
  fill: string;
  line: string;
  lineW: number;
  radius: number;
  runs: DrawingRun[];
}

export interface Drawing {
  w: number;
  h: number;
  bg: string;
  items: DrawingItem[];
}

function list<T>(v: unknown): T[] {
  return Array.isArray(v) ? (v as T[]) : v === null || v === undefined || v === "" ? [] : [v as T];
}

const num = (v: unknown, d = 0) => (Number.isFinite(Number(v)) ? Number(v) : d);

/** The drawing an option carries (a JSON string), or null when it cannot be read. */
export function parseDrawing(json: string): Drawing | null {
  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(json) as Record<string, unknown>;
  } catch {
    return null;
  }
  if (!raw || typeof raw !== "object") return null;
  const w = num(raw.w), h = num(raw.h);
  if (w <= 0 || h <= 0) return null;
  const items = list<Record<string, unknown>>(raw.items).map((it) => ({
    type: (["rect", "roundRect", "ellipse", "text"].includes(String(it.type)) ? String(it.type) : "rect") as DrawingItem["type"],
    x: num(it.x),
    y: num(it.y),
    w: num(it.w),
    h: num(it.h),
    fill: String(it.fill ?? ""),
    line: String(it.line ?? ""),
    lineW: num(it.lineW),
    radius: num(it.radius),
    runs: list<Record<string, unknown>>(it.runs).map((r) => ({ text: String(r.text ?? ""), font: String(r.font ?? ""), size: num(r.size, 12), bold: r.bold === true, color: String(r.color ?? "") })),
  }));
  return { w, h, bg: String(raw.bg ?? ""), items };
}

/** A DrawingML colour as CSS: "#RRGGBB", or the fallback for none. */
export function cssColour(hex: string, fallback = "none"): string {
  return /^[0-9a-fA-F]{6}$/.test(hex) ? `#${hex}` : fallback;
}

/** Text broken into lines that fit a width (points), at about half an em per character. */
export function wrapText(text: string, width: number, size: number): string[] {
  const perLine = Math.max(1, Math.floor(width / Math.max(1, size * 0.5)));
  const out: string[] = [];
  for (const para of text.split(/\r?\n/)) {
    let line = "";
    for (const word of para.split(/\s+/).filter(Boolean)) {
      if (!line) line = word;
      else if (line.length + 1 + word.length <= perLine) line += ` ${word}`;
      else {
        out.push(line);
        line = word;
      }
    }
    out.push(line);
  }
  return out;
}

export interface SvgText {
  x: number;
  y: number;
  anchor: "start" | "middle";
  size: number;
  bold: boolean;
  fill: string;
  font: string;
  lines: string[];
}

/** Where an item's text goes: a text item from its top left; a shape's text centred, as PowerPoint does. */
export function textLayout(it: DrawingItem, fontFamily: (font: string) => string): SvgText | null {
  const run = it.runs[0];
  if (!run || !run.text) return null;
  const pad = Math.min(7.2, it.w / 10);
  const lines = wrapText(it.runs.map((r) => r.text).join(" "), Math.max(1, it.w - 2 * pad), run.size);
  const lineH = run.size * 1.2;
  const centred = it.type !== "text";
  const block = lines.length * lineH;
  const top = centred ? it.y + Math.max(0, (it.h - block) / 2) : it.y + pad / 2;
  return {
    x: centred ? it.x + it.w / 2 : it.x + pad,
    y: top + run.size,
    anchor: centred ? "middle" : "start",
    size: run.size,
    bold: run.bold,
    fill: cssColour(run.color, "#000000"),
    font: fontFamily(run.font),
    lines,
  };
}

/** Every typeface a drawing uses. */
export function drawingFonts(d: Drawing): string[] {
  return [...new Set(d.items.flatMap((i) => i.runs.map((r) => r.font)).filter(Boolean))];
}

/**
 * Whether a font is there to draw with: document.fonts.check says yes for any font it does not need to
 * load, so the width of a test text is also compared with the fallback's (measure is injected for tests).
 */
export function fontAvailable(font: string, measure: (cssFont: string) => number, check?: (cssFont: string) => boolean): boolean {
  if (!font) return true;
  if (check && !check(`12px "${font}"`)) return false;
  for (const generic of ["monospace", "serif"]) {
    if (measure(`72px "${font}", ${generic}`) !== measure(`72px ${generic}`)) return true;
  }
  return false;
}

/** The CSS font-family for a typeface: itself when here, else a stand-in. */
export function fontFamily(font: string, available: (font: string) => boolean): string {
  return font && available(font) ? `"${font}", Arial, sans-serif` : "Arial, sans-serif";
}

/** The note under the previews when a template font is not installed in this browser. */
export function missingFontsNote(fonts: string[], available: (font: string) => boolean): string {
  const missing = fonts.filter((f) => f && !available(f));
  if (!missing.length) return "";
  return `${missing.join(", ")} ${missing.length === 1 ? "is" : "are"} not installed here, so the previews draw with a stand-in font; the deck itself keeps the template's fonts.`;
}

const seen = new Map<string, boolean>();
let ctx: CanvasRenderingContext2D | null | undefined;

/** Whether this browser has a typeface (cached): document.fonts.check and a width test on a canvas. */
export function browserHasFont(font: string): boolean {
  if (!font) return true;
  const hit = seen.get(font);
  if (hit !== undefined) return hit;
  if (ctx === undefined) ctx = typeof document !== "undefined" ? document.createElement("canvas").getContext("2d") : null;
  const c = ctx;
  const measure = (css: string) => {
    if (!c) return 0;
    c.font = css;
    return c.measureText("mmmmmmmmmmlli1WQ").width;
  };
  const check = typeof document !== "undefined" && document.fonts ? (css: string) => document.fonts.check(css) : undefined;
  const ok = c ? fontAvailable(font, measure, check) : true;
  seen.set(font, ok);
  return ok;
}
