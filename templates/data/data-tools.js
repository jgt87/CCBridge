/* Data tools: small, tested helpers for the data files in this folder (data/NAME.js sets
   window.NAMEData: a list of rows, or an object with a list per sheet). Load this file with a
   script tag before the page's own script; it sets window.DataTools. It also works as a module:
   const DataTools = require('./data-tools.js') or import it in a bundler.

   Rows are plain objects: { "Date": "2024-01-31", "Region": "North", "Amount": 1250.5 }.
   Dates are text in yyyy-MM-dd (and THH:mm:ss); numbers and true/false are already typed;
   empty cells are null.

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
    rows: rows, sheets: sheets, columns: columns, where: where, sortBy: sortBy, unique: unique,
    sum: sum, avg: avg, min: min, max: max, count: count, groupBy: groupBy, summarize: summarize,
    toDate: toDate, month: month, year: year, byMonth: byMonth,
    formatNumber: formatNumber, formatDate: formatDate, percent: percent
  };
});
