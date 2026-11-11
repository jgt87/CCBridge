// Design rules of the app's own UI (DESIGN.md, "Rules a test holds"), read from the source files.
// A failure names file:line. The hex budget is a ratchet: lower it when literals go, never raise it.
import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const src = import.meta.dirname;
const HEX_BUDGET = 22; // all in styles/markdown.css (code highlighting colours), measured 2026-11-11
const TYPE_SCALE_PX = [10, 11, 12, 13, 14, 16, 18, 20];
const TOP_PLAIN_LAYER = 50; // above it a layer has a name in index.css (--ccb-z-*)

const all = (fs.readdirSync(src, { recursive: true, encoding: "utf8" }) as string[]).map((f) => f.replace(/\\/g, "/"));
const read = (f: string) => ({ file: f, text: fs.readFileSync(path.join(src, f), "utf8") });
// Comments blanked but their line breaks kept, so a position still gives the right line.
const noComments = (s: string) => s.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
const css = all.filter((f) => f.endsWith(".css")).map(read).map((c) => ({ file: c.file, text: noComments(c.text) }));
const code = all.filter((f) => /\.tsx?$/.test(f) && !/\.test\.tsx?$/.test(f)).map(read);
const lineOf = (text: string, index: number) => text.slice(0, index).split("\n").length;

/** Every match of a pattern in a set of files, as "file:line text". */
export function hits(files: { file: string; text: string }[], pattern: RegExp, keep: (m: RegExpMatchArray) => boolean = () => true): string[] {
  const out: string[] = [];
  for (const { file, text } of files) for (const m of text.matchAll(pattern)) if (keep(m)) out.push(file + ":" + lineOf(text, m.index ?? 0) + " " + m[0].trim());
  return out;
}
const LAYOUT = /\b(all|width|height|max-height|min-height|top|left|right|bottom|inset|margin[\w-]*|padding[\w-]*)\b/;
const cssTransitions = (files: { file: string; text: string }[]) => hits(files, /(?<![\w-])transition(?:-property)?\s*:([^;}]+)/g, (m) => LAYOUT.test(m[1].replace(/var\([^)]*\)/g, "")));
const classTransitions = (files: { file: string; text: string }[]) => hits(files, /\btransition-(all|\[[^\]]*\b(width|height|max-height|top|left|right|bottom|margin|padding)\b[^\]]*\])/g);
const viewportUnits = (files: { file: string; text: string }[]) => hits(files, /(?<![\w-])(h-screen|min-h-screen|max-h-screen|w-screen)(?![\w-])|\b100v[hw]\b/g);
const bareLayers = (files: { file: string; text: string }[]) => hits(files, /(?<![\w-])z-(?:\[(\d+)\]|(\d+))(?![\w-])/g, (m) => Number(m[1] ?? m[2]) > TOP_PLAIN_LAYER);

describe("design rules of the app's own UI", () => {
  it("finds the source files (an empty run is not a pass)", () => {
    expect(css.length).toBeGreaterThan(1);
    expect(code.length).toBeGreaterThan(50);
  });
  it("keeps hex colour literals in CSS within the budget (use tokens)", () => {
    const found = hits(css, /#[0-9a-fA-F]{3,8}\b/g);
    expect(found.length, found.join("\n")).toBeLessThanOrEqual(HEX_BUDGET);
  });
  it("keeps px font sizes on the type scale", () => {
    expect(hits(css, /font-size:\s*([\d.]+)px/g, (m) => !TYPE_SCALE_PX.includes(Number(m[1])))).toEqual([]);
  });
  it("never animates layout properties, and never everything at once", () => {
    expect(cssTransitions(css)).toEqual([]);
    expect(classTransitions(code)).toEqual([]);
  });
  it("sizes to the visible window: dvh and full width, not 100vh or 100vw", () => {
    expect(viewportUnits(css)).toEqual([]);
    expect(viewportUnits(code)).toEqual([]);
  });
  it("gives every layer above the dialogs a name", () => {
    expect(bareLayers(code)).toEqual([]);
    expect(hits(css, /z-index:\s*(\d+)/g, (m) => Number(m[1]) > TOP_PLAIN_LAYER)).toEqual([]);
  });
  it("lets native controls follow the theme", () => {
    const index = css.find((c) => c.file === "index.css")!.text;
    expect(index).toMatch(/:root\s*\{\s*color-scheme:\s*light/);
    expect(index).toMatch(/\.dark\s*\{\s*color-scheme:\s*dark/);
  });
  // Each rule above is proven to catch a broken example, so a pattern that matches nothing is noticed.
  it("catches a broken example of each rule", () => {
    const bad = (text: string) => [{ file: "x", text }];
    expect(cssTransitions(bad("a { transition: all 0.2s; } b { transition: height 0.2s ease-out; } c { transition: opacity 0.2s; }"))).toHaveLength(2);
    expect(classTransitions(bad('className="transition-all" "transition-[height,opacity]" "transition" "transition-colors"'))).toHaveLength(2);
    expect(viewportUnits(bad('"flex h-screen" "h-dvh" "max-w-[85vw]" height: 100vh; width: 100vw;'))).toHaveLength(3);
    expect(bareLayers(bad('"z-[100]" "z-60" "z-50" "z-[2]" "z-(--ccb-z-hint)"'))).toHaveLength(2);
  });
});
