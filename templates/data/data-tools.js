/* Data tools v5, from the helper program. Do not edit: a newer version replaces this file.

   Helpers for the project's data. Load this file with a script tag before the page's own script
   (<script src="data/data-tools.js"></script>); it sets window.DataTools. It also works as a
   module: const DataTools = require('./data-tools.js') or import it in a bundler.

   Loading data (works for a page opened from disk and for a served page):
   DataTools.load("Source/sales.csv")    a promise of the data: a list of rows, or for a workbook
                                         an object with a list per sheet. Served over http(s), a
                                         CSV, TSV or JSON file is read and parsed here; opened
                                         from disk (where a page may not read files), the
                                         converted copy the helper program keeps (data/NAME.js)
                                         is loaded instead. The name may also be data/NAME.json
                                         or just NAME.
   DataTools.parseCsv(text)              { columns: [{ name, type }], rows } from CSV text

   Rows are plain objects: { "Date": "2024-01-31", "Region": "North", "Amount": 1250.5 }.
   Dates are text in yyyy-MM-dd (and THH:mm:ss); numbers and true/false are typed (a column is
   a number, true/false or a date only when every value in it is one); empty cells are null.

   DataTools.rows(data, sheet?)          the list of rows (a sheet's rows for a workbook)
   DataTools.sheets(data)                the sheet names of a workbook ([] for a plain list)
   DataTools.columns(rows)               the column names, in order
   DataTools.where(rows, test)           rows where test(row) is true, or test = { Column: value }
   DataTools.sortBy(rows, column, desc?) a sorted copy (numbers, dates and text; nulls last)
   DataTools.unique(rows, column)        the distinct values, sorted
   DataTools.sum / avg / min / max / count(rows, column)   (non-numbers and nulls left out; min and
                                         max of a date column give the earliest / latest date, as stored)
   DataTools.groupBy(rows, key)          [{ key, rows }] in first-seen order; key = column or function
   DataTools.summarize(rows, key, { Name: ['sum', 'Column'], Rows: ['count'] })
                                         one row per group: { key, Name, Rows }
   DataTools.toDate(text)                a Date at local midnight (no time zone shift), or null
   DataTools.month(text) / year(text)    "2024-01" / 2024 from a date text
   DataTools.byMonth(rows, dateColumn)   groupBy month, in calendar order
   DataTools.formatNumber(n, decimals?)  with the thousands separator of the page's language (html lang; else the browser's)
   DataTools.formatDate(text, options?)  a date text shown in the page's language (html lang; else the browser's)
   DataTools.percent(part, whole, decimals?)  "12.5%"

   Combining files, bands and counts (write none of these yourself):
   DataTools.join(rows, other, { on: [["Email", "Mail"], ["Name", "Full name"]] })
                                         each row with the fields of its match in other (left join:
                                         rows without a match stay, without them). on is a column
                                         both lists have, or [this column, other column] pairs tried
                                         in order (the first pair that matches wins). Keys match
                                         loosely: case, accents, spaces and punctuation do not count
                                         (match: "exact" to compare as written). A field both have
                                         keeps this row's value unless prefix: "Other " names the other's.
                                         The result has .matched and .unmatched (counts) for a notice.
                                         how: "inner" keeps only rows with a match.
   DataTools.matchKey(text)              the loose key join uses ("Garcia-Lopez, Ana" -> "garcialopezana")
   DataTools.band(x, bands, otherwise?)  the label of the first band x falls in: bands in order from
                                         the top, each { label, min } (x is a number: x >= min) or
                                         { label, when: function (x) } (x may be a row, for rules on
                                         several columns); otherwise when none fits
   DataTools.quantiles(rows, column, n)  the n-1 cut points that split the column's numbers into n
                                         groups of equal size (quartiles: n = 4), for bands from the data
   DataTools.countBy(rows, key, { sort: "desc" | "label" | false, top, missing })
                                         [{ label, value }] rows per value of a column (or function),
                                         the shape every chart reads; missing names empty values
                                         (left out without it); top keeps the largest and adds "Other"
   DataTools.countEach(rows, { Label: column or function, ... }, { sort })
                                         [{ label, value }] rows where each column is filled (not empty,
                                         0 or false) or the function is true: one bar per column, such
                                         as a count per yes/no or date column
*/
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.DataTools = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  /* ---- Reading CSV text (the same rules the helper program uses for data/NAME.json) ---------- */

  var MISSING = /^(|null|NULL|N\/A|n\/a|NA|#N\/A)$/;
  var DOT = /^[-+]?(\d+|\d{1,3}(,\d{3})+)(\.\d+)?([eE][-+]?\d+)?$/;
  var COMMA = /^[-+]?(\d+|\d{1,3}(\.\d{3})+)(,\d+)?$/;
  var ISO = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2}))?)?$/;
  var DMY = /^(\d{1,2})([/.-])(\d{1,2})\2(\d{4})(?: (\d{1,2}):(\d{2})(?::(\d{2}))?)?$/;

  function decodeText(bytes) {
    var b = new Uint8Array(bytes);
    if (b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) return new TextDecoder("utf-8").decode(b.subarray(3));
    if (b[0] === 0xff && b[1] === 0xfe) return new TextDecoder("utf-16le").decode(b.subarray(2));
    if (b[0] === 0xfe && b[1] === 0xff) return new TextDecoder("utf-16be").decode(b.subarray(2));
    try { return new TextDecoder("utf-8", { fatal: true }).decode(b); }
    catch (e) { return new TextDecoder("windows-1252").decode(b); }
  }

  function guessDelimiter(text) {
    var first = text.split("\n", 1)[0].replace(/"[^"]*"/g, "");
    var best = ",", most = 0;
    [",", ";", "\t", "|"].forEach(function (d) { var n = first.split(d).length - 1; if (n > most) { best = d; most = n; } });
    return best;
  }

  function splitCsv(text, delimiter) {
    var out = [], row = [], field = "", i = 0, quoted = false, n = text.length, any = false;
    while (i < n) {
      var ch = text[i];
      if (quoted) {
        if (ch === '"') { if (text[i + 1] === '"') { field += '"'; i += 2; continue; } quoted = false; i++; continue; }
        field += ch; i++; continue;
      }
      if (ch === '"' && field === "") { quoted = true; any = true; i++; continue; }
      if (ch === delimiter) { row.push(field); field = ""; any = true; i++; continue; }
      if (ch === "\r" || ch === "\n") {
        if (ch === "\r" && text[i + 1] === "\n") i++;
        row.push(field);
        if (any || row.length > 1 || row[0] !== "") out.push(row);
        row = []; field = ""; any = false; i++; continue;
      }
      field += ch; any = true; i++;
    }
    if (field !== "" || row.length || any) { row.push(field); out.push(row); }
    return out;
  }

  function columnType(values, delimiter) {
    var vals = values.filter(function (v) { return !MISSING.test(v); });
    if (!vals.length) return { type: "text" };
    var dot = true, comma = true, bool = true, iso = true, dmy = true, dayFirst = false, monthFirst = false, dots = true;
    for (var i = 0; i < vals.length; i++) {
      var v = vals[i];
      if (dot && !DOT.test(v)) dot = false;
      if (comma && !COMMA.test(v)) comma = false;
      if (/^[-+]?0\d/.test(v)) { dot = false; comma = false; }
      if (bool && !/^(true|false)$/i.test(v)) bool = false;
      if (iso && !ISO.test(v)) iso = false;
      if (dmy) {
        var m = DMY.exec(v);
        if (!m) dmy = false;
        else { if (+m[1] > 12) dayFirst = true; if (+m[3] > 12) monthFirst = true; if (m[2] !== ".") dots = false; }
      }
      if (!(dot || comma || bool || iso || dmy)) break;
    }
    if (dot && comma) { if (delimiter === ";") dot = false; else comma = false; }
    if (dot) return { type: "number", decimal: "." };
    if (comma) return { type: "number", decimal: "," };
    if (bool) return { type: "boolean" };
    if (iso) return { type: "date", order: "iso" };
    if (dmy) {
      if (dayFirst && monthFirst) return { type: "text" };
      if (dayFirst || (!monthFirst && dots)) return { type: "date", order: "dmy" };
      if (monthFirst) return { type: "date", order: "mdy" };
    }
    return { type: "text" };
  }

  function pad(n, w) { n = String(n); while (n.length < (w || 2)) n = "0" + n; return n; }

  function typedValue(v, t) {
    if (MISSING.test(v)) return null;
    if (t.type === "number") return Number(t.decimal === "," ? v.replace(/\./g, "").replace(",", ".") : v.replace(/,/g, ""));
    if (t.type === "boolean") return v.toLowerCase() === "true";
    if (t.type === "date") {
      var m, y, mo, d, h, mi, s;
      if (t.order === "iso") { m = ISO.exec(v); y = m[1]; mo = m[2]; d = m[3]; h = m[4]; mi = m[5]; s = m[6]; }
      else { m = DMY.exec(v); y = m[4]; h = m[5]; mi = m[6]; s = m[7]; if (t.order === "dmy") { d = m[1]; mo = m[3]; } else { mo = m[1]; d = m[3]; } }
      var out = pad(y, 4) + "-" + pad(+mo) + "-" + pad(+d);
      if (h !== undefined) out += "T" + pad(+h) + ":" + mi + ":" + (s || "00");
      return out;
    }
    return v;
  }

  function parseCsv(text, options) {
    var delimiter = (options && options.delimiter) || guessDelimiter(text);
    var table = splitCsv(text, delimiter);
    if (!table.length) return { columns: [], rows: [] };
    var width = 0;
    table.forEach(function (r) { if (r.length > width) width = r.length; });
    var names = [], seen = {}, types = [];
    for (var c = 0; c < width; c++) {
      var name = String(table[0][c] == null ? "" : table[0][c]).trim() || "Column " + (c + 1), base = name, k = 2;
      while (seen[name.toLowerCase()]) name = base + " " + k++;
      seen[name.toLowerCase()] = true;
      names.push(name);
      var vals = [];
      for (var i = 1; i < table.length; i++) vals.push(String(table[i][c] == null ? "" : table[i][c]).trim());
      types.push(columnType(vals, delimiter));
    }
    var rowsOut = [];
    for (var r = 1; r < table.length; r++) {
      var o = {};
      for (var q = 0; q < width; q++) o[names[q]] = typedValue(String(table[r][q] == null ? "" : table[r][q]).trim(), types[q]);
      rowsOut.push(o);
    }
    return { columns: names.map(function (n, x) { return { name: n, type: types[x].type }; }), rows: rowsOut };
  }

  /* ---- Loading data in a page ------------------------------------------------------------------ */

  // The project folder: the parent of the folder this script is in (data/), else the page's folder.
  var settings = { base: (function () {
    try { var s = document.currentScript && document.currentScript.src; return s ? new URL("../", s).href : ""; } catch (e) { return ""; }
  })() };

  function configure(options) { Object.keys(options || {}).forEach(function (k) { settings[k] = options[k]; }); }

  function host() { return typeof window !== "undefined" ? window : (typeof self !== "undefined" ? self : globalThis); }

  function addScript(url) {
    return new Promise(function (ok, fail) {
      var s = document.createElement("script");
      s.src = url;
      s.onload = function () { ok(); };
      s.onerror = function () { fail(new Error("Could not load " + url)); };
      document.head.appendChild(s);
    });
  }

  function normalize(path) { return String(path || "").replace(/\\/g, "/").replace(/^\.?\//, ""); }
  function stem(path) { return normalize(path).replace(/^.*\//, "").replace(/\.[^.]+$/, "").toLowerCase(); }

  // The converted files the helper program keeps (data/data-index.js sets window.DataIndex).
  function index() {
    var g = host();
    if (g.DataIndex) return Promise.resolve(g.DataIndex);
    if (typeof document === "undefined") return Promise.resolve({});
    return addScript(settings.base + "data/data-index.js").then(function () { return g.DataIndex || {}; }, function () { return {}; });
  }

  function findEntry(idx, name) {
    var key = normalize(name), lower = key.toLowerCase(), keys = Object.keys(idx), k;
    for (k = 0; k < keys.length; k++) {
      var e = idx[keys[k]];
      if (keys[k].toLowerCase() === lower || String(e.json).toLowerCase() === lower || String(e.js).toLowerCase() === lower) return e;
    }
    for (k = 0; k < keys.length; k++) if (stem(keys[k]) === stem(key) || stem(idx[keys[k]].json) === stem(key)) return idx[keys[k]];
    return null;
  }

  function served() {
    var g = host();
    return !!(g.location && /^https?:$/.test(g.location.protocol));
  }

  function parseByName(name, buffer) {
    var text = decodeText(buffer), ext = (/\.([^.]+)$/.exec(name) || ["", ""])[1].toLowerCase();
    if (ext === "json") return JSON.parse(text);
    return parseCsv(text, ext === "tsv" ? { delimiter: "\t" } : null).rows;
  }

  function fetchData(url, name) {
    return fetch(url).then(function (r) {
      if (!r.ok) throw new Error(url + ": " + r.status);
      return r.arrayBuffer();
    }).then(function (b) { return parseByName(name, b); });
  }

  function load(name) {
    return index().then(function (idx) {
      var entry = findEntry(idx, name), g = host();
      if (served()) {
        // Served: the file itself (CSV, TSV, JSON), else the converted JSON.
        var path = entry ? entry.source : normalize(name);
        var direct = /\.(csv|tsv|txt|json)$/i.test(path) ? fetchData(settings.base + path, path) : Promise.reject(new Error(path + " is not a text data file"));
        return direct.catch(function (e) {
          if (entry && entry.json) return fetchData(settings.base + entry.json, entry.json);
          throw e;
        });
      }
      // Opened from disk: the converted copy, loaded with a script tag (allowed from disk).
      if (!entry || !entry.js) {
        return Promise.reject(new Error("No converted copy of " + name + " yet. The helper program makes one at the start of the next task (Settings > Changes and commands > Prepare data files for Copilot)."));
      }
      if (g[entry.global] !== undefined) return g[entry.global];
      return addScript(settings.base + entry.js).then(function () {
        if (g[entry.global] === undefined) throw new Error(entry.js + " did not set window." + entry.global);
        return g[entry.global];
      });
    });
  }

  function rows(data, sheet) {
    if (Array.isArray(data)) return data;
    if (data && typeof data === 'object') {
      var names = Object.keys(data);
      if (sheet !== undefined) {
        if (!Array.isArray(data[sheet])) throw new Error('No sheet "' + sheet + '"; sheets: ' + names.join(', '));
        return data[sheet];
      }
      if (names.length === 1 && Array.isArray(data[names[0]])) return data[names[0]];
      throw new Error('This data has several sheets (' + names.join(', ') + '): name one, DataTools.rows(data, "' + names[0] + '")');
    }
    return [];
  }

  function sheets(data) {
    return Array.isArray(data) || !data || typeof data !== 'object' ? [] : Object.keys(data).filter(function (k) { return Array.isArray(data[k]); });
  }

  function columns(list) {
    var seen = [], index = {};
    (list || []).forEach(function (r) {
      Object.keys(r || {}).forEach(function (k) { if (!index[k]) { index[k] = true; seen.push(k); } });
    });
    return seen;
  }

  function keyFn(key) {
    return typeof key === 'function' ? key : function (r) { return r == null ? null : r[key]; };
  }

  function where(list, test) {
    if (typeof test === 'function') return list.filter(test);
    var keys = Object.keys(test || {});
    return list.filter(function (r) {
      return keys.every(function (k) {
        var want = test[k];
        if (typeof want === 'function') return want(r[k]);
        if (Array.isArray(want)) return want.indexOf(r[k]) !== -1;
        return r[k] === want;
      });
    });
  }

  function compare(a, b) {
    if (a === b) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    if (typeof a === 'number' && typeof b === 'number') return a - b;
    return String(a).localeCompare(String(b), undefined, { numeric: true });
  }

  function sortBy(list, column, desc) {
    var get = keyFn(column);
    return list.slice().sort(function (x, y) {
      var a = get(x), b = get(y);
      if (a == null || b == null) return compare(a, b);   // nulls last in both directions
      return desc ? compare(b, a) : compare(a, b);
    });
  }

  function unique(list, column) {
    var get = keyFn(column), seen = new Set();
    list.forEach(function (r) { var v = get(r); if (v != null) seen.add(v); });
    return Array.from(seen).sort(compare);
  }

  function numbers(list, column) {
    var get = keyFn(column);
    return list.map(get).filter(function (v) { return typeof v === 'number' && isFinite(v); });
  }

  function sum(list, column) { return numbers(list, column).reduce(function (a, b) { return a + b; }, 0); }
  function avg(list, column) { var n = numbers(list, column); return n.length ? sum(list, column) / n.length : null; }
  // The smallest or largest value: numbers when the column has them, else dates (yyyy-mm-dd text, with
  // or without a time, or Date objects), returned as stored; null when there are neither. A loop, not
  // Math.max.apply, which fails on very long lists.
  function dateKey(v) {
    if (v instanceof Date) return v.getTime();
    if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}/.test(v)) { var t = Date.parse(v.length === 10 ? v + 'T00:00:00' : v); return isNaN(t) ? null : t; }
    return null;
  }
  function extreme(list, column, larger) {
    var n = numbers(list, column);
    if (n.length) { var r = n[0]; for (var i = 1; i < n.length; i++) { if (larger ? n[i] > r : n[i] < r) r = n[i]; } return r; }
    var get = keyFn(column), best = null, bestKey = null;
    list.forEach(function (row) {
      var v = get(row), k = dateKey(v);
      if (k !== null && (bestKey === null || (larger ? k > bestKey : k < bestKey))) { best = v; bestKey = k; }
    });
    return best;
  }
  function min(list, column) { return extreme(list, column, false); }
  function max(list, column) { return extreme(list, column, true); }
  function count(list, column) {
    if (column === undefined) return list.length;
    var get = keyFn(column);
    return list.filter(function (r) { return get(r) != null; }).length;
  }

  function groupBy(list, key) {
    var get = keyFn(key), groups = new Map();
    list.forEach(function (r) {
      var k = get(r);
      if (!groups.has(k)) groups.set(k, []);
      groups.get(k).push(r);
    });
    return Array.from(groups, function (e) { return { key: e[0], rows: e[1] }; });
  }

  var MEASURES = { sum: sum, avg: avg, min: min, max: max, count: count };

  function summarize(list, key, measures) {
    return groupBy(list, key).map(function (g) {
      var out = { key: g.key };
      Object.keys(measures || {}).forEach(function (name) {
        var m = measures[name], fn = MEASURES[m[0]];
        if (!fn) throw new Error('Unknown measure "' + m[0] + '" (use sum, avg, min, max or count)');
        out[name] = fn(g.rows, m[1]);
      });
      return out;
    });
  }

  function toDate(text) {
    if (text instanceof Date) return text;
    var m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2}))?)?$/.exec(String(text == null ? '' : text));
    if (!m) return null;
    return new Date(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0));
  }

  function month(text) { var m = /^(\d{4}-\d{2})/.exec(String(text == null ? '' : text)); return m ? m[1] : null; }
  function year(text) { var m = /^(\d{4})/.exec(String(text == null ? '' : text)); return m ? +m[1] : null; }

  function byMonth(list, dateColumn) {
    return sortBy(groupBy(list, function (r) { return month(r[dateColumn]); }), 'key');
  }

  // The page's language (html lang="en") decides the separators; without it, the browser's.
  function pageLang() {
    try { var l = typeof document !== 'undefined' && document.documentElement && document.documentElement.lang; return l ? String(l) : undefined; } catch (e) { return undefined; }
  }

  function formatNumber(n, decimals) {
    if (typeof n !== 'number' || !isFinite(n)) return '';
    var o = decimals === undefined ? { maximumFractionDigits: 2 } : { minimumFractionDigits: decimals, maximumFractionDigits: decimals };
    return n.toLocaleString(pageLang(), o);
  }

  function formatDate(text, options) {
    var d = toDate(text);
    return d ? d.toLocaleDateString(pageLang(), options || { year: 'numeric', month: 'short', day: 'numeric' }) : '';
  }

  function percent(part, whole, decimals) {
    if (!whole) return '';
    return formatNumber(part / whole * 100, decimals === undefined ? 1 : decimals) + '%';
  }

  // Combining two lists by a key, loosely (case, accents, spaces and punctuation do not count).
  function matchKey(v) {
    if (v == null) return '';
    var t = String(v);
    if (t.normalize) t = t.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
    t = t.toLowerCase().trim();
    return t.indexOf('@') > 0 ? t.replace(/[^a-z0-9@._-]+/g, '') : t.replace(/[^a-z0-9]+/g, '');   // an e-mail address keeps its dots
  }
  function join(list, other, opts) {
    opts = opts || {};
    var on = opts.on, pairs;
    if (Array.isArray(on)) pairs = on.map(function (p) { return Array.isArray(p) ? p : [p, p]; });
    else pairs = [[on, opts.otherOn || on]];
    var exact = opts.match === 'exact', prefix = opts.prefix || '';
    var norm = function (v) { return exact ? (v == null ? '' : String(v)) : matchKey(v); };
    var maps = pairs.map(function (p) {
      var m = new Map(), get = keyFn(p[1]);
      (other || []).forEach(function (r) { var k = norm(get(r)); if (k && !m.has(k)) m.set(k, r); });
      return { get: keyFn(p[0]), map: m };
    });
    var out = [], matched = 0;
    (list || []).forEach(function (r) {
      var hit = null;
      for (var i = 0; i < maps.length && !hit; i++) { var k = norm(maps[i].get(r)); if (k) hit = maps[i].map.get(k) || null; }
      if (!hit && opts.how === 'inner') return;
      var row = {};
      Object.keys(r || {}).forEach(function (k) { row[k] = r[k]; });
      if (hit) {
        matched++;
        Object.keys(hit).forEach(function (k) {
          if (prefix) row[prefix + k] = hit[k];
          else if (!(k in row)) row[k] = hit[k];
        });
      }
      out.push(row);
    });
    out.matched = matched;
    out.unmatched = (list || []).length - matched;
    return out;
  }

  // Bands (tiers): the first band from the top that x falls in.
  function band(x, bands, otherwise) {
    for (var i = 0; i < (bands || []).length; i++) {
      var b = bands[i];
      if (typeof b.when === 'function' ? b.when(x) : (typeof x === 'number' && isFinite(x) && x >= b.min)) return b.label;
    }
    return otherwise === undefined ? null : otherwise;
  }
  function quantiles(list, column, n) {
    var v = numbers(list, column).sort(function (a, b) { return a - b; }), cuts = [];
    if (!v.length || !(n > 1)) return cuts;
    for (var i = 1; i < n; i++) {
      var pos = (v.length - 1) * i / n, lo = Math.floor(pos), hi = Math.ceil(pos);
      cuts.push(v[lo] + (v[hi] - v[lo]) * (pos - lo));
    }
    return cuts;
  }

  // Counts in the shape charts read: [{ label, value }].
  function sortCounts(list, how) {
    if (how === false) return list;
    if (how === 'label') return list.sort(function (a, b) { return compare(a.label, b.label); });
    return list.sort(function (a, b) { return b.value - a.value || compare(a.label, b.label); });
  }
  function countBy(list, key, opts) {
    opts = opts || {};
    var get = keyFn(key), m = new Map();
    (list || []).forEach(function (r) {
      var k = get(r);
      if (k == null || k === '') { if (opts.missing === undefined) return; k = opts.missing; }
      m.set(k, (m.get(k) || 0) + 1);
    });
    var out = sortCounts(Array.from(m, function (e) { return { label: e[0], value: e[1] }; }), opts.sort === undefined ? 'desc' : opts.sort);
    if (opts.top > 0 && out.length > opts.top) {
      var rest = out.slice(opts.top).reduce(function (a, b) { return a + b.value; }, 0);
      out = out.slice(0, opts.top).concat([{ label: opts.otherLabel || 'Other', value: rest }]);
    }
    return out;
  }
  function countEach(list, columnsMap, opts) {
    opts = opts || {};
    var out = Object.keys(columnsMap || {}).map(function (label) {
      var c = columnsMap[label];
      var test = typeof c === 'function' ? c : function (r) { var v = r == null ? null : r[c]; return !(v == null || v === '' || v === 0 || v === false); };
      return { label: label, value: (list || []).filter(function (r) { return test(r); }).length };
    });
    return sortCounts(out, opts.sort === undefined ? 'desc' : opts.sort);
  }

  return {
    load: load, configure: configure, parseCsv: parseCsv,
    rows: rows, sheets: sheets, columns: columns, where: where, sortBy: sortBy, unique: unique,
    sum: sum, avg: avg, min: min, max: max, count: count, groupBy: groupBy, summarize: summarize,
    toDate: toDate, month: month, year: year, byMonth: byMonth,
    formatNumber: formatNumber, formatDate: formatDate, percent: percent,
    matchKey: matchKey, join: join, band: band, quantiles: quantiles, countBy: countBy, countEach: countEach
  };
});
