/* Data tools v2, from the helper program. Do not edit: a newer version replaces this file.

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
   DataTools.sum / avg / min / max / count(rows, column)   (non-numbers and nulls left out)
   DataTools.groupBy(rows, key)          [{ key, rows }] in first-seen order; key = column or function
   DataTools.summarize(rows, key, { Name: ['sum', 'Column'], Rows: ['count'] })
                                         one row per group: { key, Name, Rows }
   DataTools.toDate(text)                a Date at local midnight (no time zone shift), or null
   DataTools.month(text) / year(text)    "2024-01" / 2024 from a date text
   DataTools.byMonth(rows, dateColumn)   groupBy month, in calendar order
   DataTools.formatNumber(n, decimals?)  with the browser's thousands separator
   DataTools.formatDate(text, options?)  a date text shown in the browser's language
   DataTools.percent(part, whole, decimals?)  "12.5%"
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
  function min(list, column) { var n = numbers(list, column); return n.length ? Math.min.apply(null, n) : null; }
  function max(list, column) { var n = numbers(list, column); return n.length ? Math.max.apply(null, n) : null; }
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

  function formatNumber(n, decimals) {
    if (typeof n !== 'number' || !isFinite(n)) return '';
    var o = decimals === undefined ? { maximumFractionDigits: 2 } : { minimumFractionDigits: decimals, maximumFractionDigits: decimals };
    return n.toLocaleString(undefined, o);
  }

  function formatDate(text, options) {
    var d = toDate(text);
    return d ? d.toLocaleDateString(undefined, options || { year: 'numeric', month: 'short', day: 'numeric' }) : '';
  }

  function percent(part, whole, decimals) {
    if (!whole) return '';
    return formatNumber(part / whole * 100, decimals === undefined ? 1 : decimals) + '%';
  }

  return {
    load: load, configure: configure, parseCsv: parseCsv,
    rows: rows, sheets: sheets, columns: columns, where: where, sortBy: sortBy, unique: unique,
    sum: sum, avg: avg, min: min, max: max, count: count, groupBy: groupBy, summarize: summarize,
    toDate: toDate, month: month, year: year, byMonth: byMonth,
    formatNumber: formatNumber, formatDate: formatDate, percent: percent
  };
});
