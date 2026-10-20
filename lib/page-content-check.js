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
//   the kit does not have). Returned with the list of classes, not as a problem text;
// - icons: kit icons (data-kit-icon) that draw nothing because the page never loaded kit-icons.js;
// - escape: parts that stick out of their table cell, panel, card or grid cell.
// ASCII only: special characters are built from their code points.
// The whole file is one expression (the test and Get-PageContentScript evaluate it as such): every
// check is a function inside it, run in order at the end.
(async () => {
  const found = [];
  const ch = (...codes) => String.fromCharCode(...codes);
  const visible = (el) => !!(el && el.getClientRects().length && getComputedStyle(el).visibility !== "hidden");
  const short = (s, n) => { s = String(s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 3) + "..." : s; };
  const firstClass = (el) => (el.className && typeof el.className === "string" ? el.className.trim().split(/\s+/)[0] : "");
  const panelHeading = (el, panels) => {
    const panel = el.closest(panels);
    const head = panel && panel.querySelector("h1, h2, h3, h4, .kit-panel__title");
    return head && head.textContent.trim() ? short(head.textContent, 50) : null;
  };
  const CARD_PANELS = ".kit-panel, section, article, .card, [class*=panel], [class*=card]";

  // Windows-1252 characters for the bytes 0x80..0x9F (the rest of 0x80..0xFF are the same code point).
  const w1252 = { 0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E,
    0x2018: 0x91, 0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F };
  const tailChars = Object.keys(w1252).map((k) => ch(Number(k))).join("");
  const range = (a, b) => ch(a) + "-" + ch(b);
  const tail = "[" + range(0x80, 0xBF) + tailChars + "]";
  const seq = new RegExp("(?:[" + range(0xC2, 0xDF) + "]" + tail + "|[" + range(0xE0, 0xEF) + "]" + tail + "{2}|[" + range(0xF0, 0xF4) + "]" + tail + "{3})+", "g");
  const decoder = new TextDecoder("utf-8", { fatal: true });
  // A Latin or Greek/Cyrillic letter: what a two-character sequence most likely was.
  const isLikelyLetter = (c) => (c >= 0xA0 && c <= 0x17F) || (c >= 0x370 && c <= 0x4FF);
  const toBytes = (s) => {
    const bytes = [];
    for (const c of s) {
      const code = c.codePointAt(0);
      if (code <= 0xFF) bytes.push(code); else if (w1252[code] !== undefined) bytes.push(w1252[code]); else return null;
    }
    return bytes;
  };
  const repair = (s) => {
    const bytes = toBytes(s);
    if (bytes === null) return null;
    try {
      const out = decoder.decode(new Uint8Array(bytes));
      if (s.length === 2 && out.length === 1 && !isLikelyLetter(out.charCodeAt(0))) return null;
      return out;
    } catch (e) { return null; }   // not valid UTF-8: not a broken sequence
  };

  // 1. Encoding.
  const findBrokenText = () => {
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
    return { hits: hits, total: total };
  };
  const checkEncoding = () => {
    const cs = String(document.characterSet || "").toUpperCase();
    const { hits, total } = findBrokenText();
    if (hits.size) {
      const list = [...hits].map(([bad, h]) => "'" + bad + "' should be '" + h.fixed + "' (in '" + h.context + "')").join("; ");
      found.push({ kind: "encoding", text: "shows broken characters, UTF-8 text read as Windows-1252" + (total > 1 ? " (" + total + " places)" : "") + ": " + list +
        (cs !== "UTF-8" ? "; the page is read as " + cs + ": put <meta charset=\"utf-8\"> first in <head>" : "; the text itself is broken in the file or the data: write the real characters and read and write files as UTF-8") });
      return;
    }
    const readAsOther = cs && cs !== "UTF-8";
    if (readAsOther && /[^\x00-\x7F]/.test((document.documentElement.outerHTML || "").slice(0, 200000))) {
      found.push({ kind: "encoding", text: "is read as " + cs + ", not UTF-8, so characters like an en dash or an accented letter can show as broken text: put <meta charset=\"utf-8\"> first in <head>" });
    }
  };

  // Fading and moving parts at their end state before measuring.
  const stopMotion = () => {
    const still = document.createElement("style");
    still.textContent = "*, *::before, *::after { transition: none !important; animation: none !important; }";
    document.head.appendChild(still);
    if (document.body) void document.body.offsetHeight;   // a document without a body (an SVG or XML file): nothing to settle
  };

  // Tables a person sees: not the screen-reader copy of a chart's data, nothing clipped to a dot.
  const shownTables = () => [...document.querySelectorAll("table, [role=table], [role=grid]")].filter((t) => {
    if (!visible(t) || t.closest(".kit-chart, .kit-chart__table, .kit-calendar, [aria-hidden=true]")) return false;
    const r = t.getBoundingClientRect();
    return r.width > 2 && r.height > 2;
  });
  // The heading just above the element (or above the box it sits in).
  const headingAbove = (t) => {
    for (let el = t; el && el !== document.body; el = el.parentElement) {
      for (let p = el.previousElementSibling; p; p = p.previousElementSibling) {
        if (/^H[1-6]$/.test(p.tagName) && p.textContent.trim()) return short(p.textContent, 50);
        if (p.querySelector && p.querySelector("table")) break;
      }
    }
    return null;
  };
  const tableName = (t, i) => {
    const cap = t.querySelector("caption");
    if (cap && cap.textContent.trim()) return short(cap.textContent, 50);
    if (t.getAttribute("aria-label")) return short(t.getAttribute("aria-label"), 50);
    return panelHeading(t, CARD_PANELS) || headingAbove(t) || "table " + (i + 1);
  };
  const isBodyRow = (r) => !r.closest("thead") && !r.hasAttribute("data-kit-empty") && !r.querySelector("th[scope=col], [role=columnheader]") && visible(r);
  const bodyRows = (t) => [...t.querySelectorAll("tbody tr, [role=row]")].filter(isBodyRow);
  const CELLS = "td, th, [role=cell], [role=gridcell]";

  // 2. Bars that go with a percentage in a table row.
  const pctRe = /(-?\d+(?:[.,]\d+)?)\s?%/g;
  const notBarShaped = (r, f) => r.width < 24 || r.height < 2 || r.height > 40 || f.height < r.height * 0.5;
  const isPainted = (fs) => (fs.backgroundColor && !/rgba\(0, 0, 0, 0\)|transparent/.test(fs.backgroundColor)) || fs.backgroundImage !== "none";
  // An element drawn as a bar: a kit-progress, or an empty track with one painted fill.
  const asBar = (el) => {
    const progress = el.classList.contains("kit-progress");
    const kids = el.children;
    const fill = progress ? el.querySelector(".kit-progress__bar") : (kids.length === 1 ? kids[0] : null);
    if (!fill) return null;
    const r = el.getBoundingClientRect(), f = fill.getBoundingClientRect();
    if (notBarShaped(r, f)) return null;
    if (!progress && (el.textContent.trim() || fill.children.length)) return null;
    if (!isPainted(getComputedStyle(fill)) && !progress) return null;
    const cs = getComputedStyle(el);
    const inner = el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
    if (inner <= 0) return null;
    return { el: el, share: Math.max(0, Math.min(1, f.width / inner)), width: inner };
  };
  const barsIn = (row) => {
    const out = [];
    for (const el of row.querySelectorAll("*")) {
      if (!visible(el)) continue;
      const bar = asBar(el);
      if (bar) out.push(bar);
    }
    return out.filter((b) => !out.some((o) => o !== b && o.el.contains(b.el)));
  };
  // The percentage a bar should show: the row's one percentage, else the bar's own aria values.
  const wantedPercent = (row, bar) => {
    const pcts = [...String(row.innerText || "").matchAll(pctRe)].map((m) => parseFloat(m[1].replace(",", ".")));
    if (pcts.length === 1) return pcts[0];
    const now = parseFloat(bar.el.getAttribute("aria-valuenow"));
    const max = parseFloat(bar.el.getAttribute("aria-valuemax") || "100"), min = parseFloat(bar.el.getAttribute("aria-valuemin") || "0");
    return !isNaN(now) && max > min ? (now - min) / (max - min) * 100 : null;
  };
  const checkTableBars = (t, i) => {
    const wrong = [];
    let checked = 0;
    for (const row of bodyRows(t)) {
      const bars = barsIn(row);
      if (bars.length !== 1) continue;
      const bar = bars[0];
      const want = wantedPercent(row, bar);
      if (want === null) continue;
      checked++;
      const expect = Math.max(0, Math.min(100, want));
      const shown = bar.share * 100;
      if (Math.abs(shown - expect) > Math.max(2, 200 / bar.width)) {   // not inverted: a width that could not be measured (NaN) is no finding
        const label = short(row.querySelector(CELLS) ? row.querySelector(CELLS).innerText : row.innerText, 30);
        wrong.push("'" + label + "' shows " + (Math.round(want * 10) / 10) + "% but its bar is " + Math.round(shown) + "% full");
      }
    }
    if (wrong.length) {
      found.push({ kind: "bar", text: "bars in '" + tableName(t, i) + "' do not show their percentage (" + wrong.length + " of " + checked + " rows): " + wrong.slice(0, 3).join("; ") +
        ": a bar next to a percentage fills exactly that share of its track (width: PERCENT%), not scaled to the largest row" });
    }
  };
  const checkBars = (tables) => { for (const [i, t] of tables.entries()) checkTableBars(t, i); };

  // 3. Parts that show nothing: a chart with nothing drawn, a table with no rows and no empty state,
  // and an error message the page shows (the data did not load).
  const nameOf = (el, i, what) => {
    if (el.getAttribute("aria-label")) return short(el.getAttribute("aria-label"), 50);
    const head = panelHeading(el, CARD_PANELS);
    if (head) return head;
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
  const isChartEmpty = (box) => {
    const canvases = box.tagName === "CANVAS" ? [box] : [...box.querySelectorAll("canvas")];
    const hasSvg = !!box.querySelector("svg *, img, table, .kit-empty, .kit-barlist__row");
    return canvases.length ? !canvases.some(drawn) && !hasSvg : !hasSvg && !box.textContent.trim();
  };
  const checkChart = (box, i) => {
    const r = box.getBoundingClientRect();
    // A kit chart that drew nothing has no height at all: that is the case to report, not to skip.
    const declared = box.hasAttribute("data-kit-chart") || box.classList.contains("kit-chart");
    if (!declared && (r.width < 40 || r.height < 30)) return;
    if (box.closest("[aria-busy=true]") || box.querySelector(".kit-skeleton")) return;   // still loading
    const empty = isChartEmpty(box);
    if (box.hasAttribute && box.hasAttribute("data-kit-shape-error")) found.push({ kind: "error", text: "chart '" + nameOf(box, i, "chart") + "' was given its data in a shape it does not read: " + (box.textContent || "").trim() });
    if (empty) found.push({ kind: "empty", text: "chart '" + nameOf(box, i, "chart") + "' shows nothing: no chart was drawn" + (box.hasAttribute("data-kit-chart") ? " (a declared kit chart: data-kit-chart \"" + box.getAttribute("data-kit-chart") + "\" with data-kit-data)" : "") + ". Make the chart draw with the data the page has (check the data you pass it and that styles/kit/kit-charts.js is loaded; KitCharts." + (box.getAttribute("data-kit-chart") || "bar") + "(element, data) draws one from code). A kit-empty message is only for when there is no data to show, written by your code in that case; never replace a chart with a fixed empty state" });
  };
  const checkCharts = () => {
    const charts = [...document.querySelectorAll(".kit-chart, [data-kit-chart], canvas")].filter((c) => visible(c) && !c.closest(".kit-chart__table"));
    const seen = new Set();
    charts.forEach((c, i) => {
      const box = c.closest(".kit-chart, [data-kit-chart]") || c;
      if (seen.has(box)) return;
      seen.add(box);
      checkChart(box, i);
    });
  };
  const hasRowsOrState = (t) => bodyRows(t).length || t.querySelector("[data-kit-empty], .kit-empty") || t.closest("[aria-busy=true]");
  const checkEmptyTables = (tables) => {
    tables.forEach((t, i) => {
      if (hasRowsOrState(t)) return;
      if (!t.querySelector("th, [role=columnheader]")) return;
      found.push({ kind: "empty", text: "table '" + tableName(t, i) + "' has no rows and no empty state: check the data it gets, and add a row with data-kit-empty that says what is missing" });
    });
  };
  const checkErrorMessages = () => {
    const errs = [...document.querySelectorAll(".kit-notice--error, [role=alert]")].filter((e) => visible(e) && e.textContent.trim());
    if (errs.length) found.push({ kind: "error", text: "shows an error message: '" + short(errs[0].textContent, 160) + "'" + (errs.length > 1 ? " (and " + (errs.length - 1) + " more)" : "") + ": find out why (often the data did not load or has another shape) and fix it" });
  };
  const checkEmpty = (tables) => {
    checkCharts();
    checkEmptyTables(tables);
    checkErrorMessages();
  };

  // 4. Every table can be sorted by its columns: clicking a header reorders the rows.
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const cellsOf = (r) => [...r.querySelectorAll(CELLS)];
  const headRowOf = (t) => t.querySelector("thead tr") || [...t.querySelectorAll("tr, [role=row]")].find((r) => r.querySelector("th, [role=columnheader]"));
  // Columns with at least two different values (sorting a column of equal values shows nothing).
  const testableColumns = (heads, rows) => heads.map((h, c) => ({ h: h, c: c })).filter((x) => x.h.innerText.trim() && !x.h.querySelector("a[href], input, select")
    && new Set(rows.map((r) => (cellsOf(r)[x.c] ? cellsOf(r)[x.c].innerText.trim() : ""))).size > 1).slice(0, 3);
  const sortsWhenClicked = async (t, testable) => {
    const order = () => bodyRows(t).map((r) => r.innerText).join("\n");
    const before = order();
    for (const x of testable) {
      const target = x.h.querySelector("button, [role=button]") || x.h;
      for (let k = 0; k < 2; k++) {
        target.click();
        await wait(150);
        if (order() !== before) return true;
      }
    }
    return false;
  };
  const checkSorting = async (tables) => {
    for (const [i, t] of tables.entries()) {
      const rows = bodyRows(t);
      if (rows.length < 3) continue;
      const headRow = headRowOf(t);
      if (!headRow) continue;
      const testable = testableColumns([...headRow.querySelectorAll("th, [role=columnheader]")], rows);
      if (!testable.length) continue;
      if (await sortsWhenClicked(t, testable)) continue;
      found.push({ kind: "sort", text: "table '" + tableName(t, i) + "' (" + rows.length + " rows) cannot be sorted: clicking its column headers does not reorder the rows; make every column sortable (with the UI kit: data-kit-sort on the table, th.kit-num for numbers)" });
    }
  };

  // 5. Markup or script shown as text: a tag or a line of code in what a person reads (tags written
  //    with entities, markup given to textContent, a script block without its tag), and the opposite
  //    damage: a tag that lost its >, whose text and next tag the browser read as attributes.
  // Whole tag names: a search in one string would also skip P, A, I, S and EM (parts of other names).
  const LEAK_SKIP = ["SCRIPT", "STYLE", "TEXTAREA", "PRE", "CODE", "NOSCRIPT", "TEMPLATE", "XMP", "TITLE"];
  const tagRe = /<\/?[a-zA-Z][\w-]*(\s[^<>]{0,200})?\/?>/;
  // A tag that lost its <: a known name, bare or with attributes, ending in > (div class="x">, /div>).
  const tagNames = "a|b|p|i|u|em|strong|small|br|hr|div|span|h[1-6]|section|article|aside|header|footer|main|nav|ul|ol|li|dl|dt|dd|table|thead|tbody|tfoot|tr|td|th|caption|a|img|input|button|label|select|option|textarea|form|fieldset|legend|script|link|meta|style|title|body|html|head|pre|code|canvas|svg|path|g|figure|figcaption|details|summary|dialog|template|iframe|video";
  const brokenRe = new RegExp("(^|\\s)(/(" + tagNames + ")>|(" + tagNames + ")/?>|(" + tagNames + ")(\\s+[\\w:.-]+=(\"[^\"]*\"|'[^']*'))+\\s*/?>)");
  const codeRe = /\b(document|window)\.\w+\s*\(|\.addEventListener\s*\(|\.querySelector(All)?\s*\(|\.getElementById\s*\(|\bfunction\s*\w*\s*\([^)]*\)\s*\{|=>\s*\{/;
  const where = (el) => { const p = el.closest("[id]"); return p ? " (inside #" + p.id + ")" : (el.className && typeof el.className === "string" ? " (inside ." + firstClass(el) + ")" : ""); };
  const notReadText = (el) => !el || LEAK_SKIP.indexOf(el.tagName) >= 0 || el.closest("pre, code, textarea, noscript, template, [aria-hidden=true]") || !visible(el);
  // The first text that holds markup and the first that holds code.
  const findShownSource = () => {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let markup = null, code = null;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const el = node.parentElement;
      if (notReadText(el)) continue;
      const s = node.nodeValue;
      if (!s || s.length < 8) continue;
      if (!markup && (tagRe.test(s) || brokenRe.test(s))) markup = { s: s, el: el };
      else if (!code && codeRe.test(s)) code = { s: s, el: el };
      if (markup && code) break;
    }
    return { markup: markup, code: code };
  };
  // A tag that lost its >: the browser read the text or the tag after it as attribute names, so one
  // of them holds a < (what follows is not on the page, and a script tag there never loaded).
  const attributeWithTag = (el) => {
    for (let k = 0; k < el.attributes.length; k++) { if (el.attributes[k].name.indexOf("<") >= 0) return el.attributes[k].name; }
    return null;
  };
  const checkLeaks = () => {
    const { markup, code } = findShownSource();
    if (markup) found.push({ kind: "leak", text: "shows HTML markup as plain text: '" + short(markup.s, 120) + "'" + where(markup.el) + ": the tags are written with entities in the page, a tag lost its <, or a script gives markup to textContent/innerText (use innerHTML, or build the elements); the file check names the line" });
    if (code) found.push({ kind: "leak", text: "shows script code as plain text: '" + short(code.s, 120) + "'" + where(code.el) + ": the <script> tag around that code is missing or damaged, so put <script> ... </script> around it; the file check names the line" });
    const all = document.getElementsByTagName("*");
    for (let i = 0; i < all.length && i < 20000; i++) {
      const el = all[i];
      const bad = attributeWithTag(el);
      if (!bad) continue;
      found.push({ kind: "leak", text: "the <" + el.tagName.toLowerCase() + "> tag" + where(el) + " has no >: the browser read what followed it ('" + short(bad, 60) + "') as attributes, so that text or tag is not on the page (a script tag there never loaded); close the tag with >, the file check names the line" });
      break;
    }
  };

  // 6. Clickable parts a keyboard cannot reach: a pointer cursor, a click handler or role=button on an
  //    element that is not a button, link, field or focusable (no tabindex), outside any such element.
  //    The outermost such element counts (its children show the same cursor). The kit's own charts and
  //    calendar make their parts buttons themselves and are left out.
  const FOCUSABLE = "a[href], button, input, select, textarea, summary, [tabindex], [contenteditable], label, option, iframe, audio[controls], video[controls]";
  const isReachableOrExempt = (el) => el.matches(FOCUSABLE) || el.closest(FOCUSABLE) || el.closest(".kit-chart, .kit-calendar, [aria-hidden=true], svg");
  const isClickable = (el) => getComputedStyle(el).cursor === "pointer" || el.hasAttribute("onclick") || el.getAttribute("role") === "button";
  const parentClickable = (el) => { const p = el.parentElement; return p && p !== document.body && getComputedStyle(p).cursor === "pointer"; };
  const unreachableClickable = (el) => !isReachableOrExempt(el) && visible(el) && isClickable(el) && !parentClickable(el);
  const describeElement = (el) => {
    const cls = firstClass(el);
    const name = "<" + el.tagName.toLowerCase() + (el.id ? "#" + el.id : (cls ? "." + cls : "")) + ">";
    const label = short(el.textContent, 30);
    return name + (label ? " '" + label + "'" : "");
  };
  const checkKeyboard = () => {
    const all = document.body ? document.body.getElementsByTagName("*") : [];
    const hits = []; let count = 0;
    for (let i = 0; i < all.length && i < 20000; i++) {
      const el = all[i];
      if (!unreachableClickable(el)) continue;
      count++;
      if (hits.length < 3) hits.push(describeElement(el));
    }
    if (count) found.push({ kind: "keyboard", text: "has " + count + " clickable part" + (count > 1 ? "s" : "") + " a keyboard cannot reach (a pointer cursor, a click handler or role=\"button\" on something that is not a button, link or focusable): " + hits.join(", ") + ": make each a <button> (or give it role=\"button\", tabindex=\"0\" and the same action on Enter and Space); with the UI kit, tables sort with data-kit-sort and charts filter with \"selectable\"" });
  };

  // 7. Dates shown as data where people read them: ISO dates (2026-07-16) or a two-digit year
  //    (16 Jul 26) as the whole text of a cell, figure or list item.
  const isoRe = /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/;
  const shortYearRe = /^\d{1,2}[ -][A-Za-z]{3}[ -]\d{2}$/;
  // The leaf elements whose whole text is a value (none inside a chart's table, code or hidden parts).
  const valueLeaves = (selector, outside) => {
    const els = document.querySelectorAll(selector);
    const out = [];
    for (let i = 0; i < els.length && i < 20000; i++) {
      const el = els[i];
      if (el.children.length || el.closest(outside) || !visible(el)) continue;
      out.push({ el: el, s: (el.textContent || "").trim() });
    }
    return out;
  };
  const placeOf = (el) => {
    const t = el.closest("table"); if (t) return " in '" + tableName(t, 0) + "'";
    const p = el.closest(".kit-panel, section, article"); const h = p && p.querySelector("h1, h2, h3, h4, .kit-panel__title");
    return h && h.textContent.trim() ? " in '" + short(h.textContent, 50) + "'" : "";
  };
  const checkDates = () => {
    let iso = 0, shortY = 0, isoEx = null, shortEx = null, at = null;
    for (const { el, s } of valueLeaves("td, th, dd, li, p, span, div, time, .kit-figure__value, .kit-figure__note", ".kit-chart__table, [aria-hidden=true], pre, code, option, [data-kit-stamp], [data-kit-stamp-of]")) {
      if (s.length < 8 || s.length > 32) continue;
      if (isoRe.test(s)) { iso++; if (!isoEx) { isoEx = s; at = el; } }
      else if (shortYearRe.test(s)) { shortY++; if (!shortEx) { shortEx = s; if (!at) at = el; } }
    }
    if (iso) found.push({ kind: "date", text: "shows " + iso + " date" + (iso > 1 ? "s" : "") + " in ISO form (such as '" + isoEx + "'" + placeOf(at) + "): people read day month year (16 Jul 2026): format dates for display (with the UI kit KitUI.format.date(iso)) and keep the ISO value in data-sort" });
    if (shortY) found.push({ kind: "date", text: "shows " + shortY + " date" + (shortY > 1 ? "s" : "") + " with a two-digit year (such as '" + shortEx + "'): write the full year (16 Jul 2026; with the UI kit KitUI.format.date)" });
  };
  // Numbers of four or more digits shown without thousands separators (8377, 2195) in figures and
  // table cells: hard to read, and inconsistent next to the ones that have them. Years (1900-2100)
  // and codes with leading zeros are left alone.
  const plainRe = /^-?\d{4,}(?:[.,]\d+)?$/;
  const isPlainNumber = (s) => {
    if (!plainRe.test(s) || /^-?0\d/.test(s)) return false;
    const n = Math.abs(parseFloat(s.replace(",", ".")));
    return !(n >= 1900 && n <= 2100 && Number.isInteger(n));
  };
  const checkNumbers = () => {
    let plain = 0, plainEx = null, plainAt = null;
    for (const { el, s } of valueLeaves("td, .kit-figure__value, dd", ".kit-chart__table, [aria-hidden=true], pre, code")) {
      if (!isPlainNumber(s)) continue;
      plain++; if (!plainEx) { plainEx = s; plainAt = el; }
    }
    if (plain) found.push({ kind: "number", text: "shows " + plain + " number" + (plain > 1 ? "s" : "") + " of four or more digits without thousands separators (such as '" + plainEx + "'" + placeOf(plainAt) + "): format numbers for display (with the UI kit KitUI.format.number(n), or DataTools.formatNumber) so every number on the page reads the same; keep the raw value in data-sort" });
  };
  const checkDatesAndNumbers = () => {
    checkDates();
    checkNumbers();
  };

  // 8. Kit classes without a rule: every kit-* class on an element, after the page's scripts ran, against
  //    the selectors of every stylesheet the page loaded (inside @media too). The served page is
  //    sandboxed (an opaque origin), where reading a stylesheet's rules throws a SecurityError: such a
  //    sheet is fetched as text instead (the preview allows it) and its kit class names taken from it.
  //    Only when every stylesheet could be read one way or the other: otherwise nothing is reported.
  const kitClassRe = /\.kit-[A-Za-z0-9_-]+/g;
  const usedKitClasses = () => {
    const used = new Set();
    document.querySelectorAll('[class*="kit-"]').forEach((el) => {
      if (el.closest("template")) return;
      for (const c of el.classList) if (/^kit-[A-Za-z0-9_-]+$/.test(c)) used.add(c);
    });
    return used;
  };
  const addKitNames = (defined, text) => { const m = text.match(kitClassRe); if (m) m.forEach((x) => defined.add(x.slice(1))); };
  const walkRules = (rules, defined) => {
    for (const r of rules) {
      if (r.selectorText) addKitNames(defined, r.selectorText);
      if (r.cssRules) walkRules(r.cssRules, defined);
    }
  };
  // A sheet whose rules cannot be read: its text, fetched (throws when that fails too).
  const readSheetText = async (sheet, defined) => {
    if (!sheet.href) throw new Error("no address");
    const r = await fetch(sheet.href);
    if (!r.ok) throw new Error("status " + r.status);
    addKitNames(defined, (await r.text()).replace(/\/\*[\s\S]*?\*\//g, " "));
  };
  const definedKitClasses = async () => {
    const defined = new Set();
    let readable = true;
    for (const sheet of document.styleSheets) {
      try { walkRules(sheet.cssRules, defined); continue; } catch (e) { /* not readable as rules: read its text */ }
      try { await readSheetText(sheet, defined); } catch (e) { readable = false; }   // unread: report nothing
    }
    return { defined: defined, readable: readable };
  };
  const checkKitClasses = async () => {
    const used = usedKitClasses();
    if (!used.size) return;
    const { defined, readable } = await definedKitClasses();
    const missing = [...used].filter((c) => !defined.has(c)).sort();
    if (readable && missing.length) found.push({ kind: "kitcss", classes: missing.slice(0, 200) });
  };

  // 9. Kit icons that draw nothing: data-kit-icon elements while the page never loaded the kit's icon
  //    script, so each shows as empty space. With the script loaded, an unknown name is reported
  //    when the helper program writes the icons, and the script warns in the console.
  const checkIcons = () => {
    if (window.KitIcons) return;
    const icons = [...document.querySelectorAll("[data-kit-icon]")].filter((el) => !el.querySelector("svg"));
    if (!icons.length) return;
    const names = [...new Set(icons.map((el) => el.getAttribute("data-kit-icon")))].slice(0, 5);
    found.push({ kind: "icons", text: "shows " + icons.length + " kit icon" + (icons.length > 1 ? "s" : "") + " (" + names.join(", ") + ") as empty space: the page never loads the kit's icon script; add <script src=\"styles/kit/kit-icons.js\"></script> after the markup (the path to styles/kit/kit-icons.js from this page)" });
  };

  // 10. Parts that stick out of their box: an element that runs past the edge of the table cell,
  //     panel, card or grid cell holding it (a fixed width, white-space: nowrap, a long word or a
  //     picture wider than the cell). Left out: a box that scrolls or clips (its overflow is not
  //     visible), and parts that float on purpose (position absolute or fixed: menus, tips,
  //     popovers) or are hidden.
  const BOXES = "td, th, [role=cell], [role=gridcell], .kit-panel, .kit-figure, .kit-board__card, .kit-bento__item, .kit-list__item, .card, .kit-grid > *, .kit-figures > *, .kit-bento > *";
  const clips = (el) => { const s = getComputedStyle(el); return /auto|scroll|hidden|clip/.test(s.overflowX + " " + s.overflowY + " " + s.overflow); };
  const floats = (el) => { const p = getComputedStyle(el).position; return p === "absolute" || p === "fixed"; };
  const boxName = (el) => { const tag = el.tagName.toLowerCase(); return tag === "td" || tag === "th" || /cell/.test(el.getAttribute("role") || "") ? "table cell" : "<" + tag + (firstClass(el) ? "." + firstClass(el) : "") + ">"; };
  const sticksOut = (box, b) => {
    const out = [];
    const walk = (el) => {
      for (const c of el.children) {
        if (c.matches("script, style, template, svg, canvas, [hidden], [aria-hidden=true], .kit-sr-only, .kit-chart__table") || floats(c) || !visible(c)) continue;
        const r = c.getBoundingClientRect();
        const past = Math.max(r.right - b.right, b.left - r.left, r.bottom - b.bottom, b.top - r.top);
        if (r.width && r.height && past > 2) { out.push({ el: c, past: Math.round(past), side: r.right - b.right > 2 ? "right" : b.left - r.left > 2 ? "left" : r.bottom - b.bottom > 2 ? "bottom" : "top" }); continue; }
        if (!clips(c)) walk(c);
      }
    };
    walk(box);
    return out;
  };
  const checkEscapes = () => {
    const hits = []; let count = 0;
    const boxes = document.querySelectorAll(BOXES);
    for (let i = 0; i < boxes.length && i < 4000; i++) {
      const box = boxes[i];
      if (clips(box) || !visible(box) || box.closest("svg, [aria-hidden=true]")) continue;
      // Measured from the box's border: padding is inside the box, so a part in the padding is fine.
      const parts = sticksOut(box, box.getBoundingClientRect());
      // Text of the box itself wider than the box (white-space: nowrap, a long word): no element to name.
      const over = box.scrollWidth - box.clientWidth;
      if (!parts.length && over > 2 && [...box.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) {
        count++;
        if (hits.length < 3) hits.push("the text '" + short(box.textContent, 30) + "' runs " + over + " px past the right edge of its " + boxName(box));
        continue;
      }
      for (const o of parts) {
        // Inside a smaller box that is checked itself: said there, once.
        if (o.el.parentElement !== box && o.el.parentElement.closest(BOXES) !== box) continue;
        count++;
        if (hits.length < 3) hits.push(describeElement(o.el) + " runs " + o.past + " px past the " + o.side + " edge of its " + boxName(box));
      }
    }
    if (count) found.push({ kind: "escape", text: "has " + count + " part" + (count > 1 ? "s" : "") + " sticking out of their box: " + hits.join("; ") + ": let each fit its box (no fixed width or white-space: nowrap wider than the cell, long words allowed to break, max-width: 100% on pictures and fields), or give the box room; a wide table goes in a kit-table-wrap, which scrolls by itself" });
  };

  // Each check catches its own failure: the ones after it still run, and what was found so far is reported.
  try { checkEncoding(); } catch (e) { /* the other checks still run */ }
  stopMotion();
  const tables = shownTables();
  const checks = [
    () => checkBars(tables),
    () => checkEmpty(tables),
    () => checkSorting(tables),
    checkLeaks,
    checkKeyboard,
    checkDatesAndNumbers,
    checkKitClasses,
    checkIcons,
    checkEscapes,
  ];
  for (const check of checks) {
    try { await check(); } catch (e) { /* the next check still runs */ }
  }

  return JSON.stringify(found);
})()
