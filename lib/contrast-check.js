// WCAG AA contrast on a loaded page, run by StreamHub's page check (Runtime.evaluate). Measures the
// visible text against the background it sits on (see-through layers mixed in) and the borders of
// form fields; returns JSON: [{ ratio, need, kind, fg, bg, text, where, count }]. Text over images
// or gradients is left out (its background cannot be known). Read-only: changes nothing on the page.
(() => {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  const cache = new Map();
  // Any CSS colour (rgb, hex, oklch, color()) to sRGB 0-255 plus alpha, through the canvas.
  const rgba = (c) => {
    if (cache.has(c)) return cache.get(c);
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = "#000";
    ctx.fillStyle = c;
    ctx.fillRect(0, 0, 1, 1);
    const d = ctx.getImageData(0, 0, 1, 1).data;
    const v = { r: d[0], g: d[1], b: d[2], a: d[3] / 255 };
    cache.set(c, v);
    return v;
  };
  const over = (top, under) => ({
    r: top.r * top.a + under.r * (1 - top.a),
    g: top.g * top.a + under.g * (1 - top.a),
    b: top.b * top.a + under.b * (1 - top.a),
    a: 1,
  });
  const lum = (c) => {
    const f = (x) => {
      const s = x / 255;
      return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  };
  const ratio = (a, b) => {
    const x = lum(a), y = lum(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  };
  const hex = (c) => "#" + [c.r, c.g, c.b].map((x) => Math.round(x).toString(16).padStart(2, "0")).join("");
  const canvasBase = () => {
    const html = getComputedStyle(document.documentElement).backgroundColor;
    const body = document.body ? getComputedStyle(document.body).backgroundColor : "";
    let base = { r: 255, g: 255, b: 255, a: 1 };
    // The browser's canvas follows the page's color-scheme (dark pages get a dark canvas).
    if (getComputedStyle(document.documentElement).colorScheme.includes("dark") && matchMedia("(prefers-color-scheme: dark)").matches) base = { r: 18, g: 18, b: 18, a: 1 };
    for (const c of [html, body]) { const v = rgba(c); if (v.a > 0) base = over(v, base); }
    return base;
  };
  const base = canvasBase();
  // The colour behind an element: its own and its ancestors' backgrounds, mixed; null over an image.
  const backgroundOf = (el) => {
    const layers = [];
    for (let e = el; e && e !== document.documentElement; e = e.parentElement) {
      const s = getComputedStyle(e);
      if (s.backgroundImage && s.backgroundImage !== "none") return null;
      const v = rgba(s.backgroundColor);
      if (v.a > 0) { layers.push(v); if (v.a >= 1) break; }
    }
    let c = base;
    for (let i = layers.length - 1; i >= 0; i--) c = over(layers[i], c);
    return c;
  };
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    for (let e = el; e; e = e.parentElement) {
      const s = getComputedStyle(e);
      if (s.display === "none" || s.visibility === "hidden" || Number(s.opacity) < 0.1) return false;
      if (e.getAttribute && e.getAttribute("aria-hidden") === "true") return false;
    }
    return true;
  };
  const describe = (el) => {
    const id = el.id ? "#" + el.id : "";
    const cls = typeof el.className === "string" && el.className.trim() ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".") : "";
    return el.tagName.toLowerCase() + id + cls;
  };
  const found = new Map();
  const add = (kind, el, fg, bg, need, text) => {
    const r = ratio(fg, bg);
    if (r >= need) return;
    const key = kind + hex(fg) + hex(bg) + need;
    const f = found.get(key);
    if (f) { f.count++; return; }
    found.set(key, { ratio: Math.round(r * 100) / 100, need, kind, fg: hex(fg), bg: hex(bg), text: (text || "").trim().slice(0, 50), where: describe(el), count: 1 });
  };
  const disabled = (el) => el.closest("[disabled], [aria-disabled='true']") !== null;
  // Click targets (WCAG 2.5.8: at least 24 x 24 px) and names of controls (images, icon-only buttons).
  const interactive = "a[href], button, input[type=button], input[type=submit], input[type=reset], input[type=checkbox], input[type=radio], select, [role=button], [role=link], [role=tab], [role=checkbox], [role=switch]";
  // The accessible name, roughly: aria-label, title, the label of a field, the text, a button's value.
  const nameOf = (el) => {
    const labelText = el.labels && el.labels.length ? Array.from(el.labels).map((l) => l.innerText).join(" ") : "";
    const by = el.getAttribute("aria-labelledby");
    const byText = by ? by.split(/\s+/).map((id) => (document.getElementById(id) || {}).innerText || "").join(" ") : "";
    const isChoice = el.tagName === "INPUT" && ["checkbox", "radio"].includes(el.type);
    const img = el.querySelector && el.querySelector("img[alt]:not([alt=''])");
    return (el.getAttribute("aria-label") || byText || labelText || el.getAttribute("title") || el.innerText || (isChoice ? "" : el.value) || (img ? img.alt : "") || "").trim();
  };
  // The area that reacts to a click: a field inside (or tied to) a label is clicked through the label too.
  const targetRect = (el) => {
    let r = el.getBoundingClientRect();
    if (el.labels) for (const l of el.labels) {
      const q = l.getBoundingClientRect();
      if (q.width && q.height) r = { left: Math.min(r.left, q.left), top: Math.min(r.top, q.top), right: Math.max(r.right, q.right), bottom: Math.max(r.bottom, q.bottom), width: 0, height: 0 };
    }
    return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.right - r.left, height: r.bottom - r.top };
  };
  const extra = new Map();
  const note = (kind, el, info) => {
    const key = kind + describe(el);
    const f = extra.get(key);
    if (f) { f.count++; return; }
    extra.set(key, Object.assign({ kind, where: describe(el), count: 1 }, info));
  };
  const targets = Array.from(document.body ? document.body.querySelectorAll(interactive) : []).filter((el) => visible(el) && !disabled(el));
  const rects = targets.map(targetRect);
  targets.forEach((el, i) => {
    const r = rects[i];
    // Excused by WCAG 2.5.8: a link inside a sentence, and a small target with room around it
    // (a 24 px circle on its centre overlaps no other target).
    const inText = el.tagName === "A" && el.parentElement && Array.from(el.parentElement.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim());
    if (!inText && (r.width < 24 || r.height < 24)) {
      const cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
      const crowded = rects.some((q, j) => {
        if (j === i) return false;
        const nx = Math.max(q.left, Math.min(cx, q.right)), ny = Math.max(q.top, Math.min(cy, q.bottom));
        return Math.hypot(nx - cx, ny - cy) < 12;
      });
      if (crowded) note("target", el, { text: nameOf(el).slice(0, 40), w: Math.round(r.width), h: Math.round(r.height) });
    }
    if (!nameOf(el) && el.tagName !== "SELECT") note("name", el, { text: "" });
  });
  for (const img of document.body ? document.body.querySelectorAll("img:not([alt])") : []) { if (visible(img)) note("name", img, { text: img.getAttribute("src") || "" }); }
  // Alignment: page-level blocks (header contents, sections, headings, panels, tables, forms) whose
  // left or right edge is a few pixels from a shared edge are almost always an accident; larger
  // offsets are deliberate indents and are left alone.
  const blocks = [];
  const vw = document.documentElement.clientWidth;
  const sel = "header, nav, main, section, article, footer, h1, h2, h3, table, form, .kit-panel, .kit-band, .kit-toolbar, [class*='container']";
  for (const el of document.body ? document.body.querySelectorAll(sel) : []) {
    if (!visible(el)) continue;
    const r = el.getBoundingClientRect(), s = getComputedStyle(el);
    if (r.width < vw * 0.3 || s.position === "fixed" || s.position === "absolute") continue;
    // A block that fills the width (a header bar) counts with its padding: its contents start there.
    const full = r.width >= vw - 2;
    const left = full ? r.left + parseFloat(s.paddingLeft) : r.left;
    const right = full ? r.right - parseFloat(s.paddingRight) : r.right;
    if (full && parseFloat(s.paddingLeft) === 0) continue;   // its children carry the edge
    blocks.push({ el, left: Math.round(left), right: Math.round(right) });
  }
  const edgeIssue = (side) => {
    const counts = new Map();
    blocks.forEach((b) => counts.set(b[side], (counts.get(b[side]) || 0) + 1));
    const main = Array.from(counts.entries()).sort((a, b) => b[1] - a[1])[0];
    if (!main || main[1] < 2) return;
    const reported = [];
    for (const b of blocks) {
      const off = Math.abs(b[side] - main[0]);
      if (off < 1 || off > 12) continue;
      // Set in by the border of a wrapper around it (a framed table): the wrapper is the edge you see.
      let border = 0;
      for (let e = b.el.parentElement, i = 0; e && i < 3; e = e.parentElement, i++) {
        const st = getComputedStyle(e);
        border += parseFloat(side === "left" ? st.borderLeftWidth : st.borderRightWidth) + parseFloat(side === "left" ? st.paddingLeft : st.paddingRight);
        if (Math.abs(border - off) < 0.6) break;
      }
      if (Math.abs(border - off) < 0.6) continue;
      // Inside a block already reported on this edge: the same problem, said once.
      if (reported.some((r) => r.el.contains(b.el) && r[side] === b[side])) continue;
      reported.push(b);
      const key = "align" + side + describe(b.el);
      if (extra.has(key)) { extra.get(key).count++; continue; }
      extra.set(key, { kind: "align", where: describe(b.el), count: 1, side, off, at: b[side], main: main[0], text: (b.el.innerText || "").trim().split("\n")[0].slice(0, 30) });
    }
  };
  edgeIssue("left");
  edgeIssue("right");
  let checked = 0;
  for (const el of document.body ? document.body.querySelectorAll("*") : []) {
    if (checked > 3000) break;
    if (["SCRIPT", "STYLE", "NOSCRIPT", "SVG", "PATH", "IMG", "CANVAS", "VIDEO", "TEMPLATE", "BR"].includes(el.tagName)) continue;
    const own = Array.from(el.childNodes).filter((n) => n.nodeType === 3 && n.textContent.trim()).map((n) => n.textContent).join(" ");
    const isField = ["INPUT", "SELECT", "TEXTAREA"].includes(el.tagName) && !["hidden", "checkbox", "radio", "range", "color", "file", "submit", "button", "image", "reset"].includes(el.type);
    if (!own && !isField) continue;
    if (!visible(el) || disabled(el)) continue;
    checked++;
    const s = getComputedStyle(el);
    const bg = backgroundOf(el);
    if (!bg) continue;
    if (own) {
      const size = parseFloat(s.fontSize) || 16;
      const bold = (parseInt(s.fontWeight, 10) || 400) >= 700;
      const large = size >= 24 || (size >= 18.66 && bold);
      add("text", el, over(rgba(s.color), bg), bg, large ? 3 : 4.5, own);
    }
    if (isField) {
      // The field's edge must stand out from what is around it (WCAG 1.4.11), unless its own fill does.
      const around = el.parentElement ? backgroundOf(el.parentElement) : base;
      if (!around) continue;
      const fill = backgroundOf(el);
      if (ratio(fill, around) >= 3) continue;
      const bw = parseFloat(s.borderTopWidth) + parseFloat(s.borderBottomWidth);
      if (bw > 0) add("border", el, over(rgba(s.borderTopColor), around), around, 3, el.getAttribute("aria-label") || el.placeholder || el.name || "");
    }
  }
  return JSON.stringify(Array.from(found.values()).sort((a, b) => a.ratio - b.ratio).slice(0, 12).concat(Array.from(extra.values()).slice(0, 10)));
})()
