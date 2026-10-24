// WCAG AA contrast on a loaded page, run by StreamHub's page check (Runtime.evaluate). Measures the
// visible text against the background it sits on (see-through layers mixed in) and the borders of
// form fields; returns JSON: [{ ratio, need, kind, fg, bg, text, where, count }]. Text over images
// or gradients is left out (its background cannot be known). Read-only: changes nothing on the page.
// The whole file is one expression (Get-ContrastScript evaluates it as such): every check is a
// function inside it, run in order at the end.
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
  // Names of controls (images, icon-only buttons), and sizes that do not match: controls side by side
  // of different heights, and the same control (tag and classes) in different heights on the page.
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
  const extra = new Map();
  const note = (kind, el, info) => {
    const key = kind + describe(el);
    const f = extra.get(key);
    if (f) { f.count++; return; }
    extra.set(key, Object.assign({ kind, where: describe(el), count: 1 }, info));
  };
  const all = (selector) => (document.body ? Array.from(document.body.querySelectorAll(selector)) : []);
  // Controls a person can use but that have no name (a select is named by its choice).
  const checkControlNames = () => {
    const targets = all(interactive).filter((el) => visible(el) && !disabled(el));
    targets.forEach((el) => { if (!nameOf(el) && el.tagName !== "SELECT") note("name", el, { text: "" }); });
  };
  // Sizes: buttons and single-line fields. Differences of a few pixels are rounding; a wrapped label
  // (a button taller than two lines of its text) is left out.
  const sizedControls = () => all("button, [role=button], input, select").filter((el) => {
    if (!visible(el)) return false;
    if (el.tagName === "INPUT" && ["hidden", "checkbox", "radio", "range", "color", "file", "image"].includes(el.type)) return false;
    return !el.closest("table, [role=grid], [role=tablist], svg, .kit-chart, .kit-calendar, .kit-pager, .kit-tags, [aria-hidden=true]");
  }).map((el) => ({ el, r: el.getBoundingClientRect() })).filter((c) => c.r.height > 0)
    // A label that wraps (taller than two lines of its text) is as tall as its words make it.
    .filter((c) => c.r.height <= (parseFloat(getComputedStyle(c.el).lineHeight) || 20) * 2 + 24);
  const label = (el) => nameOf(el).slice(0, 30);
  const sizeNote = (a, b, scope) => {
    const key = "size" + scope + describe(a.el);
    if (extra.has(key)) { extra.get(key).count++; return; }
    extra.set(key, { kind: "size", scope, where: describe(a.el), text: label(a.el), h: Math.round(a.r.height), other: describe(b.el), otherText: label(b.el), otherH: Math.round(b.r.height), count: 1 });
  };
  // Items grouped by a key; a null key leaves the item out.
  const groupBy = (items, keyOf) => {
    const groups = new Map();
    for (const c of items) {
      const k = keyOf(c);
      if (k === null) continue;
      if (!groups.has(k)) groups.set(k, []);
      groups.get(k).push(c);
    }
    return Array.from(groups.values());
  };
  // The row of a control: the parent when it lays its children out, else the grandparent through a
  // wrapper around the control alone (a field's label); a control inside text (a tip button in a
  // heading) is a row of its own.
  const rowOf = (c) => {
    const p = c.el.parentElement;
    if (!p) return null;
    const ownText = Array.from(p.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim());
    const lays = /flex|grid/.test(getComputedStyle(p).display);
    return lays || ownText || !p.parentElement ? p : p.parentElement;
  };
  // Side by side: in one row (the same parent or grandparent, their heights overlapping), heights more
  // than 3 px apart. The smaller one is reported against the most common height of the row.
  const checkRowSizes = (sized) => {
    for (const list of groupBy(sized, rowOf)) {
      if (list.length < 2) continue;
      for (const a of list) {
        const beside = list.filter((b) => b !== a && Math.min(a.r.bottom, b.r.bottom) - Math.max(a.r.top, b.r.top) > Math.min(a.r.height, b.r.height) / 2);
        if (!beside.length) continue;
        const most = beside.slice().sort((x, y) => beside.filter((z) => Math.abs(z.r.height - y.r.height) <= 3).length - beside.filter((z) => Math.abs(z.r.height - x.r.height) <= 3).length)[0];
        if (Math.abs(a.r.height - most.r.height) > 3 && a.r.height < most.r.height) sizeNote(a, most, "row");
      }
    }
  };
  // The same control elsewhere on the page: the same tag, type and classes, heights more than 3 px apart.
  const kindOf = (c) => c.el.tagName + "|" + (c.el.type || "") + "|" + Array.from(c.el.classList).filter((x) => !/^(is-|has-|active|selected|open)/.test(x)).sort().join(" ");
  const checkKindSizes = (sized) => {
    for (const list of groupBy(sized, kindOf)) {
      if (list.length < 2) continue;
      const counts = list.map((c) => list.filter((d) => Math.abs(d.r.height - c.r.height) <= 3).length);
      const main = list[counts.indexOf(Math.max(...counts))];
      const odd = list.find((c) => Math.abs(c.r.height - main.r.height) > 3);
      if (odd) sizeNote(odd, main, "page");
    }
  };
  const checkImageNames = () => {
    for (const img of all("img:not([alt])")) { if (visible(img)) note("name", img, { text: img.getAttribute("src") || "" }); }
  };
  // Alignment: page-level blocks (header contents, sections, headings, panels, tables, forms) whose
  // left or right edge is a few pixels from a shared edge are almost always an accident; larger
  // offsets are deliberate indents and are left alone.
  const pageBlocks = () => {
    const blocks = [];
    const vw = document.documentElement.clientWidth;
    const sel = "header, nav, main, section, article, footer, h1, h2, h3, table, form, .kit-panel, .kit-band, .kit-toolbar, [class*='container']";
    for (const el of all(sel)) {
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
    return blocks;
  };
  // Set in by the border and padding of a wrapper around it (a framed table): the wrapper is the edge you see.
  const setInByWrapper = (el, side, off) => {
    let border = 0;
    for (let e = el.parentElement, i = 0; e && i < 3; e = e.parentElement, i++) {
      const st = getComputedStyle(e);
      border += parseFloat(side === "left" ? st.borderLeftWidth : st.borderRightWidth) + parseFloat(side === "left" ? st.paddingLeft : st.paddingRight);
      if (Math.abs(border - off) < 0.6) break;
    }
    return Math.abs(border - off) < 0.6;
  };
  const edgeIssue = (blocks, side) => {
    const counts = new Map();
    blocks.forEach((b) => counts.set(b[side], (counts.get(b[side]) || 0) + 1));
    const main = Array.from(counts.entries()).sort((a, b) => b[1] - a[1])[0];
    if (!main || main[1] < 2) return;
    const reported = [];
    for (const b of blocks) {
      const off = Math.abs(b[side] - main[0]);
      if (off < 1 || off > 12) continue;
      if (setInByWrapper(b.el, side, off)) continue;
      // Inside a block already reported on this edge: the same problem, said once.
      if (reported.some((r) => r.el.contains(b.el) && r[side] === b[side])) continue;
      reported.push(b);
      const key = "align" + side + describe(b.el);
      if (extra.has(key)) { extra.get(key).count++; continue; }
      extra.set(key, { kind: "align", where: describe(b.el), count: 1, side, off, at: b[side], main: main[0], text: (b.el.innerText || "").trim().split("\n")[0].slice(0, 30) });
    }
  };
  const checkAlignment = () => {
    const blocks = pageBlocks();
    edgeIssue(blocks, "left");
    edgeIssue(blocks, "right");
  };
  // Text against its background: 4.5:1, or 3:1 for large text (24 px, or 18.66 px bold).
  const textContrast = (el, s, bg, own) => {
    const size = parseFloat(s.fontSize) || 16;
    const bold = (parseInt(s.fontWeight, 10) || 400) >= 700;
    const large = size >= 24 || (size >= 18.66 && bold);
    add("text", el, over(rgba(s.color), bg), bg, large ? 3 : 4.5, own);
  };
  // The field's edge must stand out from what is around it (WCAG 1.4.11), unless its own fill does.
  const fieldEdge = (el, s) => {
    const around = el.parentElement ? backgroundOf(el.parentElement) : base;
    if (!around) return;
    const fill = backgroundOf(el);
    if (ratio(fill, around) >= 3) return;
    const bw = parseFloat(s.borderTopWidth) + parseFloat(s.borderBottomWidth);
    if (bw > 0) add("border", el, over(rgba(s.borderTopColor), around), around, 3, el.getAttribute("aria-label") || el.placeholder || el.name || "");
  };
  // Every element with text of its own and every text field, up to 3000 of them.
  const checkContrast = () => {
    let checked = 0;
    for (const el of all("*")) {
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
      if (own) textContrast(el, s, bg, own);
      if (isField) fieldEdge(el, s);
    }
  };
  // The checks, in this order: the order the notes come out in.
  checkControlNames();
  const sized = sizedControls();
  checkRowSizes(sized);
  checkKindSizes(sized);
  checkImageNames();
  checkAlignment();
  checkContrast();
  return JSON.stringify(Array.from(found.values()).sort((a, b) => a.ratio - b.ratio).slice(0, 12).concat(Array.from(extra.values()).slice(0, 10)));
})()
