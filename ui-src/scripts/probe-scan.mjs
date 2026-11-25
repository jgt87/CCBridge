// Probe theme (docs/19 §8, §12 #10): do the colour tokens actually reach the page?
// A view is read twice: as it is, then with every colour token on :root set to a probe value
// that nothing else uses. A colour that did not move with the tokens was not drawn from one: a
// literal in a component, a stale var() fallback, an inline style, an SVG fill, a value set from
// script, or a browser default on an unstyled control. A colour mixed from tokens moves too, so
// color-mix() hovers are not reported. Findings are for a person to judge ("token-reach"):
// data and user-content colours stay literal by rule (rules/ui.md), so those are expected.
// Used by check-design-rules.mjs (--probe, or "probe": true in its config); the in-page parts are
// expression strings like the other scans there, the comparison is a pure function.

/** Every drawn element's colours, by document index. `color` counts only where the element has
 *  text of its own; edges only where they have a width. */
export const probeCollect = (ignore) => `(() => {
  const ignore = ${JSON.stringify(ignore || '')};
  const els = [...document.querySelectorAll('body, body *')];
  const index = new Map(els.map((e, i) => [e, i]));
  const out = [];
  els.forEach((e, i) => {
    if (e.closest('script, style, noscript, template') || (ignore && e.closest(ignore))) return;
    const r = e.getBoundingClientRect();
    if (!(r.width > 0 && r.height > 0)) return;
    const s = getComputedStyle(e);
    if (s.visibility === 'hidden') return;
    const props = { background: s.backgroundColor };
    const svg = e instanceof SVGElement;
    if (svg || [...e.childNodes].some((n) => n.nodeType === 3 && n.nodeValue.trim())) props.color = s.color;
    if (parseFloat(s.borderTopWidth) > 0) props.border = s.borderTopColor;
    if (s.outlineStyle !== 'none' && parseFloat(s.outlineWidth) > 0) props.outline = s.outlineColor;
    if (svg) { props.fill = s.fill; props.stroke = s.stroke; }
    const cls = typeof e.className === 'string' && e.className.trim() ? '.' + e.className.trim().split(/\\s+/)[0] : '';
    out.push({ i, p: index.get(e.parentElement) ?? -1, tag: e.tagName.toLowerCase() + cls, props });
  });
  return JSON.stringify(out); })()`;

/** Sets every colour-valued custom property found in the page's style sheets to a probe value on
 *  :root, stops transitions so the change shows at once, and returns how many tokens it set. */
export const probeApply = `(() => {
  const names = new Set();
  const walk = (rules) => { for (const r of rules) { if (r.style) for (const p of r.style) if (p.startsWith('--')) names.add(p); if (r.cssRules) walk(r.cssRules); } };
  for (const sheet of document.styleSheets) { try { walk(sheet.cssRules); } catch { /* another origin's sheet */ } }
  const root = getComputedStyle(document.documentElement);
  const probe = (k) => 'rgb(' + ((37 * k + 11) % 256) + ' ' + ((91 * k + 53) % 256) + ' ' + ((173 * k + 101) % 256) + ')';
  const set = [];
  for (const n of names) { const v = root.getPropertyValue(n).trim(); if (v && CSS.supports('color', v)) set.push(n + ': ' + probe(set.length + 1) + ' !important'); }
  const style = document.createElement('style');
  style.textContent = ':root, :root[data-theme], html { ' + set.join('; ') + ' } *, *::before, *::after { transition: none !important; animation: none !important; }';
  document.head.append(style);
  return JSON.stringify(set.length); })()`;

const CLEAR = /^(transparent|none|rgba\(0, 0, 0, 0\)|rgb\(0 0 0 \/ 0\))$/;

/** "index prop" -> { b, prop, value } for every drawn colour equal in both reads of the same
 *  element (an index whose tag changed is a different element and is not compared). */
function keptColours(before, after) {
  const now = new Map(after.map((x) => [x.i, x]));
  const kept = new Map();
  for (const b of before) {
    const a = now.get(b.i);
    if (!a || a.tag !== b.tag) continue;
    for (const [prop, value] of Object.entries(b.props)) {
      if (!CLEAR.test(value) && a.props[prop] === value) kept.set(`${b.i} ${prop}`, { b, prop, value });
    }
  }
  return kept;
}

/** The colours that stayed the same while every token changed, as "tag prop value" lines. A text
 *  colour its parent also kept unchanged is inherited, so only the parent is listed. */
export function tokenReach(before, after, probed, limit = 8) {
  if (!probed) return ['no colour tokens found on :root, so nothing could be probed'];
  const kept = keptColours(before, after);
  const lines = [];
  for (const { b, prop, value } of kept.values()) {
    if (prop === 'color' && kept.get(`${b.p} color`)?.value === value) continue;
    lines.push(`${b.tag} ${prop} ${value} did not follow the tokens`);
  }
  return lines.length > limit ? [...lines.slice(0, limit), `and ${lines.length - limit} more`] : lines;
}

/** Self-test pages: one draws everything from tokens, the other has a literal colour. */
export const probePage = (ok) => 'data:text/html;charset=utf-8,' + encodeURIComponent(`<!doctype html><style>
  :root { --bg: Canvas; --ink: CanvasText; --edge: color-mix(in srgb, CanvasText 40%, Canvas); }
  body { margin: 0; background: var(--bg); color: var(--ink); font: 13px sans-serif; }
  .main { padding: 12px; border: 1px solid var(--edge); }
  .tag { color: ${ok ? 'var(--ink)' : 'GrayText'}; }
</style><div class="main">Probe <span class="tag">tag</span></div>`);
