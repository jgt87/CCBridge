// @vitest-environment jsdom
// The contrast and layout check (lib/contrast-check.js) in jsdom: text and field edges against their
// background, control names, and edges a few pixels off. jsdom has no layout or canvas: boxes come
// from data-x / data-w / data-h (0 / 100 / 50 when not given), and the canvas stand-in paints the
// rgb() or hex colour it is given.
import fs from "node:fs";
import path from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

const repo = path.resolve(import.meta.dirname, "../../..");
const script = fs.readFileSync(path.join(repo, "lib/contrast-check.js"), "utf8");
type Finding = { kind: string; where: string; ratio?: number; need?: number; fg?: string; bg?: string; text?: string; side?: string; off?: number };
const run = () => JSON.parse(new Function("return (\n" + script + "\n)")() as string) as Finding[];

const num = (el: Element, name: string, fallback: number) => {
  const v = el.getAttribute(name);
  return v === null ? fallback : Number(v);
};
// "rgb(1, 2, 3)", "rgba(1, 2, 3, 0.5)" or "#abc" / "#aabbcc" to [r, g, b, a 0-255]; null for anything else.
const paint = (c: string): number[] | null => {
  const m = /^rgba?\(\s*(\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\s*\)$/.exec(c);
  if (m) return [Number(m[1]), Number(m[2]), Number(m[3]), Math.round((m[4] === undefined ? 1 : Number(m[4])) * 255)];
  const h = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(c);
  if (!h) return null;
  const s = h[1].length === 3 ? h[1].replace(/./g, "$&$&") : h[1];
  return [0, 2, 4].map((i) => parseInt(s.slice(i, i + 2), 16)).concat(255);
};
const saved = {
  box: Element.prototype.getBoundingClientRect,
  ctx: HTMLCanvasElement.prototype.getContext,
  style: window.getComputedStyle,
};
beforeAll(() => {
  Element.prototype.getBoundingClientRect = function () {
    const x = num(this, "data-x", 0), w = num(this, "data-w", 100), h = num(this, "data-h", 50);
    return { x, y: 0, left: x, top: 0, right: x + w, bottom: h, width: w, height: h, toJSON: () => ({}) } as DOMRect;
  };
  Object.defineProperty(HTMLElement.prototype, "clientWidth", { configurable: true, get() { return num(this, "data-w", 100); } });
  Object.defineProperty(HTMLElement.prototype, "innerText", { configurable: true, get() { return this.textContent; } });
  (HTMLCanvasElement.prototype as unknown as Record<string, unknown>).getContext = () => {
    let fill = [0, 0, 0, 255];
    return {
      set fillStyle(c: string) { fill = paint(String(c)) ?? fill; },
      clearRect() {}, fillRect() {},
      getImageData: () => ({ data: fill }),
    };
  };
  // jsdom computes no opacity: every element is fully shown.
  (window as unknown as Record<string, unknown>).getComputedStyle = (el: Element) =>
    new Proxy(saved.style(el), { get: (t, k) => (k === "opacity" ? "1" : (t as unknown as Record<string | symbol, unknown>)[k]) });
});
afterEach(() => {
  document.body.innerHTML = "";
  document.documentElement.removeAttribute("data-w");
});
afterAll(() => {
  Element.prototype.getBoundingClientRect = saved.box;
  HTMLCanvasElement.prototype.getContext = saved.ctx;
  (window as unknown as Record<string, unknown>).getComputedStyle = saved.style;
  delete (HTMLElement.prototype as unknown as Record<string, unknown>).clientWidth;
  delete (HTMLElement.prototype as unknown as Record<string, unknown>).innerText;
});

describe("contrast-check.js", () => {
  it("reports text under 4.5:1, large bold text under 3:1, and nothing that passes", () => {
    document.body.innerHTML = `<div style="background: #fff">
      <p style="color: #999">Faint</p>
      <h2 style="color: #999; font-size: 24px; font-weight: 700">Big</h2>
      <p style="color: #767676">Just enough</p></div>`;
    const text = run().filter((f) => f.kind === "text");
    expect(text.map((f) => [f.where, f.ratio, f.need, f.fg, f.bg])).toEqual([
      ["p", 2.85, 4.5, "#999999", "#ffffff"],
      ["h2", 2.85, 3, "#999999", "#ffffff"],
    ]);
  });
  it("reports a field whose edge does not stand out from what is around it", () => {
    document.body.innerHTML = `<div style="background: #fff">
      <input aria-label="Pale" style="background: #fff; border: 1px solid #eee">
      <input aria-label="Clear" style="background: #fff; border: 1px solid #767676">
      <input aria-label="Filled" style="background: #333; border: 1px solid #333"></div>`;
    expect(run().filter((f) => f.kind === "border").map((f) => [f.text, f.need])).toEqual([["Pale", 3]]);
  });
  it("reports controls and images without a name, controls first", () => {
    document.body.innerHTML = `<img src="logo.png"><button class="kit-btn"></button><button>Save</button><select><option>A</option></select>`;
    expect(run().filter((f) => f.kind === "name").map((f) => [f.where, f.text])).toEqual([
      ["button.kit-btn", ""],
      ["img", "logo.png"],
    ]);
  });
  it("reports a block a few pixels off the shared edge, not an indent or a block on it", () => {
    document.documentElement.setAttribute("data-w", "1000");
    document.body.innerHTML = `
      <section data-x="16" data-w="600">One</section>
      <section data-x="16" data-w="600">Two</section>
      <section data-x="20" data-w="596">Off</section>
      <section data-x="56" data-w="560">Indent</section>`;
    const align = run().filter((f) => f.kind === "align");
    expect(align.map((f) => [f.side, f.off, f.text])).toEqual([["left", 4, "Off"]]);
  });
});
