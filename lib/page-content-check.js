// Page check, run in a throwaway tab after the page loaded (Agent Test-WebPageCore): what the page
// shows, not how it is written. Returns a JSON list of { kind, text }:
// - encoding: text broken by a wrong encoding (UTF-8 read as Windows-1252), a page not read as UTF-8;
// - bar: a table row that shows one percentage and one bar whose fill is not that percentage;
// - empty / error: a chart that draws nothing, a table with no rows and no empty state, an error message;
// - sort: a table whose column headers do not reorder its rows when clicked;
// - leak: HTML markup or script code shown as plain text (tags written as entities, a script block
//   without its tag, markup given to textContent);
// - keyboard: clickable parts (a pointer cursor or click handler) that are not buttons, links or
//   focusable, so a keyboard cannot reach them;
// - date: dates shown as data (ISO 2026-07-16, or a two-digit year) where people read them;
// - kitcss: kit classes on the page (also the ones the kit's scripts add at run time) that no loaded
//   stylesheet has a rule for: the helper program adds their rules to kit.css (or reports a class
//   the kit does not have). Returned with the list of classes, not as a problem text.
// ASCII only: special characters are built from their code points.
(async () => {
  const found = [];
  const ch = (...codes) => String.fromCharCode(...codes);
  const visible = (el) => !!(el && el.getClientRects().length && getComputedStyle(el).visibility !== "hidden");
  const short = (s, n) => { s = String(s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 3) + "..." : s; };

  // Windows-1252 characters for the bytes 0x80..0x9F (the rest of 0x80..0xFF are the same code point).
  const w1252 = { 0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E,
    0x2018: 0x91, 0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F };
  const tailChars = Object.keys(w1252).map((k) => ch(Number(k))).join("");
  const range = (a, b) => ch(a) + "-" + ch(b);
  const tail = "[" + range(0x80, 0xBF) + tailChars + "]";
  const seq = new RegExp("(?:[" + range(0xC2, 0xDF) + "]" + tail + "|[" + range(0xE0, 0xEF) + "]" + tail + "{2}|[" + range(0xF0, 0xF4) + "]" + tail + "{3})+", "g");
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const repair = (s) => {
    const bytes = [];
    for (const c of s) {
      const code = c.codePointAt(0);
      if (code <= 0xFF) bytes.push(code); else if (w1252[code] !== undefined) bytes.push(w1252[code]); else return null;
    }
    try {
      const out = decoder.decode(new Uint8Array(bytes));
      if (s.length === 2 && out.length === 1) { const c = out.charCodeAt(0); if (!((c >= 0xA0 && c <= 0x17F) || (c >= 0x370 && c <= 0x4FF))) return null; }
      return out;
    } catch (e) { return null; }
  };

  // 1. Encoding.
  try {
    const cs = String(document.characterSet || "").toUpperCase();
    const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.parentElement && /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(n.parentElement.tagName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    const hits = new Map();
    let total = 0;
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const text = n.nodeValue;
      seq.lastIndex = 0;
      for (let m = seq.exec(text); m; m = seq.exec(text)) {
        const fixed = repair(m[0]);
        if (fixed === null) continue;
        total++;
        if (!hits.has(m[0]) && hits.size < 3) hits.set(m[0], { fixed: fixed, context: short(text.slice(Math.max(0, m.index - 20), m.index + m[0].length + 20), 60) });
      }
    }
    if (hits.size) {
      const list = [...hits].map(([bad, h]) => "'" + bad + "' should be '" + h.fixed + "' (in '" + h.context + "')").join("; ");
      found.push({ kind: "encoding", text: "shows broken characters, UTF-8 text read as Windows-1252" + (total > 1 ? " (" + total + " places)" : "") + ": " + list +
        (cs !== "UTF-8" ? "; the page is read as " + cs + ": put <meta charset=\"utf-8\"> first in <head>" : "; the text itself is broken in the file or the data: write the real characters and read and write files as UTF-8") });
    } else if (cs && cs !== "UTF-8" && /[^\x00-\x7F]/.test((document.documentElement.outerHTML || "").slice(0, 200000))) {
      found.push({ kind: "encoding", text: "is read as " + cs + ", not UTF-8, so characters like an en dash or an accented letter can show as broken text: put <meta charset=\"utf-8\"> first in <head>" });
    }
  } catch (e) { /* the other checks still run */ }

  // Fading and moving parts at their end state before measuring.
  const still = document.createElement("style");
  still.textContent = "*, *::before, *::after { transition: none !important; animation: none !important; }";
  document.head.appendChild(still);
  void document.body.offsetHeight;

  // Tables a person sees: not the screen-reader copy of a chart's data, nothing clipped to a dot.
  const tables = [...document.querySelectorAll("table, [role=table], [role=grid]")].filter((t) => {
    if (!visible(t) || t.closest(".kit-chart, .kit-chart__table, .kit-calendar, [aria-hidden=true]")) return false;
    const r = t.getBoundingClientRect();
    return r.width > 2 && r.height > 2;
  });
  const tableName = (t, i) => {
    const cap = t.querySelector("caption");
    if (cap && cap.textContent.trim()) return short(cap.textContent, 50);
    if (t.getAttribute("aria-label")) return short(t.getAttribute("aria-label"), 50);
    const panel = t.closest(".kit-panel, section, article, .card, [class*=panel], [class*=card]");
    const head = panel && panel.querySelector("h1, h2, h3, h4, .kit-panel__title");
    if (head && head.textContent.trim()) return short(head.textContent, 50);
    // The heading just above the table (or above the box it sits in).
    for (let el = t; el && el !== document.body; el = el.parentElement) {
      for (let p = el.previousElementSibling; p; p = p.previousElementSibling) {
        if (/^H[1-6]$/.test(p.tagName) && p.textContent.trim()) return short(p.textContent, 50);
        if (p.querySelector && p.querySelector("table")) break;
      }
    }
    return "table " + (i + 1);
  };
  const bodyRows = (t) => [...t.querySelectorAll("tbody tr, [role=row]")].filter((r) => !r.closest("thead") && !r.hasAttribute("data-kit-empty") && !r.querySelector("th[scope=col], [role=columnheader]") && visible(r));

  // 2. Bars that go with a percentage in a table row.
  try {
    const pctRe = /(-?\d+(?:[.,]\d+)?)\s?%/g;
    const barsIn = (row) => {
      const out = [];
      for (const el of row.querySelectorAll("*")) {
        if (!visible(el)) continue;
        const kids = el.children;
        const fill = el.classList.contains("kit-progress") ? el.querySelector(".kit-progress__bar") : (kids.length === 1 ? kids[0] : null);
        if (!fill) continue;
        const r = el.getBoundingClientRect(), f = fill.getBoundingClientRect();
        if (r.width < 24 || r.height < 2 || r.height > 40 || f.height < r.height * 0.5) continue;
        if (!el.classList.contains("kit-progress") && (el.textContent.trim() || fill.children.length)) continue;
        const fs = getComputedStyle(fill);
        const painted = (fs.backgroundColor && !/rgba\(0, 0, 0, 0\)|transparent/.test(fs.backgroundColor)) || fs.backgroundImage !== "none";
        if (!painted && !el.classList.contains("kit-progress")) continue;
        const cs = getComputedStyle(el);
        const inner = el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
        if (inner <= 0) continue;
        out.push({ el: el, share: Math.max(0, Math.min(1, f.width / inner)), width: inner });
      }
      return out.filter((b) => !out.some((o) => o !== b && o.el.contains(b.el)));
    };
    for (const [i, t] of tables.entries()) {
      const wrong = [];
      let checked = 0;
      for (const row of bodyRows(t)) {
        const bars = barsIn(row);
        if (bars.length !== 1) continue;
        const bar = bars[0];
        const pcts = [...String(row.innerText || "").matchAll(pctRe)].map((m) => parseFloat(m[1].replace(",", ".")));
        let want = pcts.length === 1 ? pcts[0] : null;
        if (want === null) {
          const now = parseFloat(bar.el.getAttribute("aria-valuenow"));
          const max = parseFloat(bar.el.getAttribute("aria-valuemax") || "100"), min = parseFloat(bar.el.getAttribute("aria-valuemin") || "0");
          if (!isNaN(now) && max > min) want = (now - min) / (max - min) * 100;
        }
        if (want === null) continue;
        checked++;
        const expect = Math.max(0, Math.min(100, want));
        const shown = bar.share * 100;
        if (Math.abs(shown - expect) > Math.max(2, 200 / bar.width)) {
          const label = short(row.querySelector("td, th, [role=cell], [role=gridcell]") ? row.querySelector("td, th, [role=cell], [role=gridcell]").innerText : row.innerText, 30);
          wrong.push("'" + label + "' shows " + (Math.round(want * 10) / 10) + "% but its bar is " + Math.round(shown) + "% full");
        }
      }
      if (wrong.length) {
        found.push({ kind: "bar", text: "bars in '" + tableName(t, i) + "' do not show their percentage (" + wrong.length + " of " + checked + " rows): " + wrong.slice(0, 3).join("; ") +
          ": a bar next to a percentage fills exactly that share of its track (width: PERCENT%), not scaled to the largest row" });
      }
    }
  } catch (e) { /* the sort check still runs */ }

  // 3. Parts that show nothing: a chart with nothing drawn, a table with no rows and no empty state,
  // and an error message the page shows (the data did not load).
  try {
    const nameOf = (el, i, what) => {
      if (el.getAttribute("aria-label")) return short(el.getAttribute("aria-label"), 50);
      const panel = el.closest(".kit-panel, section, article, .card, [class*=panel], [class*=card]");
      const head = panel && panel.querySelector("h1, h2, h3, h4, .kit-panel__title");
      if (head && head.textContent.trim()) return short(head.textContent, 50);
      const n = tableName(el, i);   // the heading just above it, as for tables
      return /^table \d+$/.test(n) ? what + " " + (i + 1) : n;
    };
    const drawn = (canvas) => {
      try {
        const ctx = canvas.getContext("2d");
        if (!ctx || !canvas.width || !canvas.height) return true;
        const d = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
        const step = Math.max(4, Math.floor(d.length / 4 / 20000) * 4);   // a sample of the pixels
        for (let p = 3; p < d.length; p += step) if (d[p] > 0) return true;
        return false;
      } catch (e) { return true; }   // a canvas that cannot be read (another site's image) counts as drawn
    };
    const charts = [...document.querySelectorAll(".kit-chart, [data-kit-chart], canvas")].filter((c) => visible(c) && !c.closest(".kit-chart__table"));
    const seen = new Set();
    charts.forEach((c, i) => {
      const box = c.closest(".kit-chart, [data-kit-chart]") || c;
      if (seen.has(box)) return;
      seen.add(box);
      const r = box.getBoundingClientRect();
      // A kit chart that drew nothing has no height at all: that is the case to report, not to skip.
      const declared = box.hasAttribute("data-kit-chart") || box.classList.contains("kit-chart");
      if (!declared && (r.width < 40 || r.height < 30)) return;
      if (box.closest("[aria-busy=true]") || box.querySelector(".kit-skeleton")) return;   // still loading
      const canvases = box.tagName === "CANVAS" ? [box] : [...box.querySelectorAll("canvas")];
      const hasSvg = !!box.querySelector("svg *, img, table, .kit-empty, .kit-barlist__row");
      const empty = canvases.length ? !canvases.some(drawn) && !hasSvg : !hasSvg && !box.textContent.trim();
      if (box.hasAttribute && box.hasAttribute("data-kit-shape-error")) found.push({ kind: "error", text: "chart '" + nameOf(box, i, "chart") + "' was given its data in a shape it does not read: " + (box.textContent || "").trim() });
      if (empty) found.push({ kind: "empty", text: "chart '" + nameOf(box, i, "chart") + "' shows nothing: no chart was drawn" + (box.hasAttribute("data-kit-chart") ? " (a declared kit chart: data-kit-chart \"" + box.getAttribute("data-kit-chart") + "\" with data-kit-data)" : "") + ". Make the chart draw with the data the page has (check the data you pass it and that styles/kit/kit-charts.js is loaded; KitCharts." + (box.getAttribute("data-kit-chart") || "bar") + "(element, data) draws one from code). A kit-empty message is only for when there is no data to show, written by your code in that case; never replace a chart with a fixed empty state" });
    });
    tables.forEach((t, i) => {
      if (bodyRows(t).length || t.querySelector("[data-kit-empty], .kit-empty") || t.closest("[aria-busy=true]")) return;
      if (!t.querySelector("th, [role=columnheader]")) return;
      found.push({ kind: "empty", text: "table '" + tableName(t, i) + "' has no rows and no empty state: check the data it gets, and add a row with data-kit-empty that says what is missing" });
    });
    const errs = [...document.querySelectorAll(".kit-notice--error, [role=alert]")].filter((e) => visible(e) && e.textContent.trim());
    if (errs.length) found.push({ kind: "error", text: "shows an error message: '" + short(errs[0].textContent, 160) + "'" + (errs.length > 1 ? " (and " + (errs.length - 1) + " more)" : "") + ": find out why (often the data did not load or has another shape) and fix it" });
  } catch (e) { /* the sort check still runs */ }

  // 4. Every table can be sorted by its columns: clicking a header reorders the rows.
  try {
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    for (const [i, t] of tables.entries()) {
      const rows = bodyRows(t);
      if (rows.length < 3) continue;
      const headRow = t.querySelector("thead tr") || [...t.querySelectorAll("tr, [role=row]")].find((r) => r.querySelector("th, [role=columnheader]"));
      if (!headRow) continue;
      const heads = [...headRow.querySelectorAll("th, [role=columnheader]")];
      // Columns with at least two different values (sorting a column of equal values shows nothing).
      const cells = (r) => [...r.querySelectorAll("td, th, [role=cell], [role=gridcell]")];
      const testable = heads.map((h, c) => ({ h: h, c: c })).filter((x) => x.h.innerText.trim() && !x.h.querySelector("a[href], input, select")
        && new Set(rows.map((r) => (cells(r)[x.c] ? cells(r)[x.c].innerText.trim() : ""))).size > 1).slice(0, 3);
      if (!testable.length) continue;
      const order = () => bodyRows(t).map((r) => r.innerText).join("\n");
      const before = order();
      let sorts = false;
      for (const x of testable) {
        const target = x.h.querySelector("button, [role=button]") || x.h;
        for (let k = 0; k < 2 && !sorts; k++) {
          target.click();
          await wait(150);
          if (order() !== before) sorts = true;
        }
        if (sorts) break;
      }
      if (!sorts) {
        found.push({ kind: "sort", text: "table '" + tableName(t, i) + "' (" + rows.length + " rows) cannot be sorted: clicking its column headers does not reorder the rows; make every column sortable (with the UI kit: data-kit-sort on the table, th.kit-num for numbers)" });
      }
    }
  } catch (e) { /* what was found so far is reported */ }

  // 5. Markup or script shown as text: a tag or a line of code in what a person reads (tags written
  //    with entities, markup given to textContent, a script block without its tag), and the opposite
  //    damage: a tag that lost its >, whose text and next tag the browser read as attributes.
  try {
    const skip = "SCRIPT STYLE TEXTAREA PRE CODE NOSCRIPT TEMPLATE XMP TITLE";
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const tagRe = /<\/?[a-zA-Z][\w-]*(\s[^<>]{0,200})?\/?>/;
    // A tag that lost its <: a known name, bare or with attributes, ending in > (div class="x">, /div>).
    const names = "a|b|p|i|u|em|strong|small|br|hr|div|span|h[1-6]|section|article|aside|header|footer|main|nav|ul|ol|li|dl|dt|dd|table|thead|tbody|tfoot|tr|td|th|caption|a|img|input|button|label|select|option|textarea|form|fieldset|legend|script|link|meta|style|title|body|html|head|pre|code|canvas|svg|path|g|figure|figcaption|details|summary|dialog|template|iframe|video";
    const brokenRe = new RegExp("(^|\\s)(/(" + names + ")>|(" + names + ")/?>|(" + names + ")(\\s+[\\w:.-]+=(\"[^\"]*\"|'[^']*'))+\\s*/?>)");
    const codeRe = /\b(document|window)\.\w+\s*\(|\.addEventListener\s*\(|\.querySelector(All)?\s*\(|\.getElementById\s*\(|\bfunction\s*\w*\s*\([^)]*\)\s*\{|=>\s*\{/;
    let markup = null, code = null;
    const where = (el) => { const p = el.closest("[id]"); return p ? " (inside #" + p.id + ")" : (el.className && typeof el.className === "string" ? " (inside ." + el.className.trim().split(/\s+/)[0] + ")" : ""); };
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const el = node.parentElement;
      if (!el || skip.indexOf(el.tagName) >= 0 || el.closest("pre, code, textarea, noscript, template, [aria-hidden=true]") || !visible(el)) continue;
      const s = node.nodeValue;
      if (!s || s.length < 8) continue;
      if (!markup && (tagRe.test(s) || brokenRe.test(s))) markup = { s: s, el: el };
      else if (!code && codeRe.test(s)) code = { s: s, el: el };
      if (markup && code) break;
    }
    if (markup) found.push({ kind: "leak", text: "shows HTML markup as plain text: '" + short(markup.s, 120) + "'" + where(markup.el) + ": the tags are written with entities in the page, a tag lost its <, or a script gives markup to textContent/innerText (use innerHTML, or build the elements); the file check names the line" });
    if (code) found.push({ kind: "leak", text: "shows script code as plain text: '" + short(code.s, 120) + "'" + where(code.el) + ": the <script> tag around that code is missing or damaged, so put <script> ... </script> around it; the file check names the line" });
    // A tag that lost its >: the browser read the text or the tag after it as attribute names, so one
    // of them holds a < (what follows is not on the page, and a script tag there never loaded).
    const all = document.getElementsByTagName("*");
    for (let i = 0; i < all.length && i < 20000; i++) {
      const el = all[i]; let bad = null;
      for (let k = 0; k < el.attributes.length; k++) { if (el.attributes[k].name.indexOf("<") >= 0) { bad = el.attributes[k].name; break; } }
      if (!bad) continue;
      found.push({ kind: "leak", text: "the <" + el.tagName.toLowerCase() + "> tag" + where(el) + " has no >: the browser read what followed it ('" + short(bad, 60) + "') as attributes, so that text or tag is not on the page (a script tag there never loaded); close the tag with >, the file check names the line" });
      break;
    }
  } catch (e) { /* what was found so far is reported */ }

  // 6. Clickable parts a keyboard cannot reach: a pointer cursor, a click handler or role=button on an
  //    element that is not a button, link, field or focusable (no tabindex), outside any such element.
  //    The outermost such element counts (its children show the same cursor). The kit's own charts and
  //    calendar make their parts buttons themselves and are left out.
  try {
    const focusable = "a[href], button, input, select, textarea, summary, [tabindex], [contenteditable], label, option, iframe, audio[controls], video[controls]";
    const all = document.body ? document.body.getElementsByTagName("*") : [];
    const hits = []; let count = 0;
    for (let i = 0; i < all.length && i < 20000; i++) {
      const el = all[i];
      if (el.matches(focusable) || el.closest(focusable) || el.closest(".kit-chart, .kit-calendar, [aria-hidden=true], svg")) continue;
      if (!visible(el)) continue;
      const clickable = getComputedStyle(el).cursor === "pointer" || el.hasAttribute("onclick") || el.getAttribute("role") === "button";
      if (!clickable) continue;
      const p = el.parentElement;
      if (p && p !== document.body && getComputedStyle(p).cursor === "pointer") continue;
      count++;
      if (hits.length < 3) {
        const name = "<" + el.tagName.toLowerCase() + (el.id ? "#" + el.id : (el.className && typeof el.className === "string" && el.className.trim() ? "." + el.className.trim().split(/\s+/)[0] : "")) + ">";
        const label = short(el.textContent, 30);
        hits.push(name + (label ? " '" + label + "'" : ""));
      }
    }
    if (count) found.push({ kind: "keyboard", text: "has " + count + " clickable part" + (count > 1 ? "s" : "") + " a keyboard cannot reach (a pointer cursor, a click handler or role=\"button\" on something that is not a button, link or focusable): " + hits.join(", ") + ": make each a <button> (or give it role=\"button\", tabindex=\"0\" and the same action on Enter and Space); with the UI kit, tables sort with data-kit-sort and charts filter with \"selectable\"" });
  } catch (e) { /* what was found so far is reported */ }

  // 7. Dates shown as data where people read them: ISO dates (2026-07-16) or a two-digit year
  //    (16 Jul 26) as the whole text of a cell, figure or list item.
  try {
    const isoRe = /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/;
    const shortYearRe = /^\d{1,2}[ -][A-Za-z]{3}[ -]\d{2}$/;
    const cells = document.querySelectorAll("td, th, dd, li, p, span, div, time, .kit-figure__value, .kit-figure__note");
    let iso = 0, shortY = 0, isoEx = null, shortEx = null, at = null;
    for (let i = 0; i < cells.length && i < 20000; i++) {
      const el = cells[i];
      if (el.children.length || el.closest(".kit-chart__table, [aria-hidden=true], pre, code, option, [data-kit-stamp], [data-kit-stamp-of]") || !visible(el)) continue;
      const s = (el.textContent || "").trim();
      if (s.length < 8 || s.length > 32) continue;
      if (isoRe.test(s)) { iso++; if (!isoEx) { isoEx = s; at = el; } }
      else if (shortYearRe.test(s)) { shortY++; if (!shortEx) { shortEx = s; if (!at) at = el; } }
    }
    const place = (el) => {
      const t = el.closest("table"); if (t) return " in '" + tableName(t, 0) + "'";
      const p = el.closest(".kit-panel, section, article"); const h = p && p.querySelector("h1, h2, h3, h4, .kit-panel__title");
      return h && h.textContent.trim() ? " in '" + short(h.textContent, 50) + "'" : "";
    };
    if (iso) found.push({ kind: "date", text: "shows " + iso + " date" + (iso > 1 ? "s" : "") + " in ISO form (such as '" + isoEx + "'" + place(at) + "): people read day month year (16 Jul 2026): format dates for display (with the UI kit KitUI.format.date(iso)) and keep the ISO value in data-sort" });
    if (shortY) found.push({ kind: "date", text: "shows " + shortY + " date" + (shortY > 1 ? "s" : "") + " with a two-digit year (such as '" + shortEx + "'): write the full year (16 Jul 2026; with the UI kit KitUI.format.date)" });
    // Numbers of four or more digits shown without thousands separators (8377, 2195) in figures and
    // table cells: hard to read, and inconsistent next to the ones that have them. Years (1900-2100)
    // and codes with leading zeros are left alone.
    const plainRe = /^-?\d{4,}(?:[.,]\d+)?$/;
    const nums = document.querySelectorAll("td, .kit-figure__value, dd");
    let plain = 0, plainEx = null, plainAt = null;
    for (let i = 0; i < nums.length && i < 20000; i++) {
      const el = nums[i];
      if (el.children.length || el.closest(".kit-chart__table, [aria-hidden=true], pre, code") || !visible(el)) continue;
      const s = (el.textContent || "").trim();
      if (!plainRe.test(s) || /^-?0\d/.test(s)) continue;
      const n = Math.abs(parseFloat(s.replace(",", ".")));
      if (n >= 1900 && n <= 2100 && Number.isInteger(n)) continue;
      plain++; if (!plainEx) { plainEx = s; plainAt = el; }
    }
    if (plain) found.push({ kind: "number", text: "shows " + plain + " number" + (plain > 1 ? "s" : "") + " of four or more digits without thousands separators (such as '" + plainEx + "'" + place(plainAt) + "): format numbers for display (with the UI kit KitUI.format.number(n), or DataTools.formatNumber) so every number on the page reads the same; keep the raw value in data-sort" });
  } catch (e) { /* what was found so far is reported */ }

  // 8. Kit classes without a rule: every kit-* class on an element, after the page's scripts ran, against
  //    the selectors of every stylesheet the page loaded (inside @media too). The served page is
  //    sandboxed (an opaque origin), where reading a stylesheet's rules throws a SecurityError: such a
  //    sheet is fetched as text instead (the preview allows it) and its kit class names taken from it.
  //    Only when every stylesheet could be read one way or the other: otherwise nothing is reported.
  try {
    const used = new Set();
    document.querySelectorAll('[class*="kit-"]').forEach((el) => {
      if (el.closest("template")) return;
      for (const c of el.classList) if (/^kit-[A-Za-z0-9_-]+$/.test(c)) used.add(c);
    });
    if (used.size) {
      const defined = new Set();
      let readable = true;
      const walk = (rules) => {
        for (const r of rules) {
          if (r.selectorText) { const m = r.selectorText.match(/\.kit-[A-Za-z0-9_-]+/g); if (m) m.forEach((x) => defined.add(x.slice(1))); }
          if (r.cssRules) walk(r.cssRules);
        }
      };
      for (const sheet of document.styleSheets) {
        try { walk(sheet.cssRules); continue; } catch (e) { /* not readable as rules: read its text */ }
        try {
          if (!sheet.href) throw new Error("no address");
          const r = await fetch(sheet.href);
          if (!r.ok) throw new Error("status " + r.status);
          const css = (await r.text()).replace(/\/\*[\s\S]*?\*\//g, " ");
          const m = css.match(/\.kit-[A-Za-z0-9_-]+/g);
          if (m) m.forEach((x) => defined.add(x.slice(1)));
        } catch (e) { readable = false; }
      }
      const missing = [...used].filter((c) => !defined.has(c)).sort();
      if (readable && missing.length) found.push({ kind: "kitcss", classes: missing.slice(0, 200) });
    }
  } catch (e) { /* what was found so far is reported */ }

  return JSON.stringify(found);
})()
