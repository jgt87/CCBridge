/*
  UI kit: SQL in the page. SQLite through sql.js (MIT licence, vendor/sqljs/: its pure-JavaScript
  build, so it also works in a page opened from disk). Load vendor/sqljs/sql-asm.js, then this file:
    <script src="styles/kit/vendor/sqljs/sql-asm.js"></script>
    <script src="styles/kit/kit-sql.js"></script>
  KitSql.open({ sales: rows, people: rows2 }).then(function (db) {
    var byRegion = db.query("SELECT region, SUM(amount) AS total FROM sales GROUP BY region ORDER BY total DESC");
  });
  Each list of row objects becomes a table (columns from the rows; numbers as numbers, true/false as
  1/0, everything else as text: dates in yyyy-mm-dd sort and compare as they should).
  db.query(sql, params?) gives row objects; db.run(sql, params?) changes data; db.add(name, rows) adds a
  table; db.tables() lists them; db.close() frees the memory.
*/
(function () {
  "use strict";
  var ready = null;
  function engine() {
    if (!ready) {
      if (typeof initSqlJs !== "function") return Promise.reject(new Error("KitSql needs styles/kit/vendor/sqljs/sql-asm.js loaded before kit-sql.js"));
      ready = initSqlJs();
    }
    return ready;
  }
  function quote(name) { return "\"" + String(name).replace(/"/g, "\"\"") + "\""; }
  function columnsOf(rows) {
    var seen = {}, cols = [];
    rows.slice(0, 500).forEach(function (r) { Object.keys(r || {}).forEach(function (k) { if (!seen[k]) { seen[k] = true; cols.push(k); } }); });
    return cols;
  }
  function typeOf(rows, col) {
    var t = null;
    for (var i = 0; i < rows.length && i < 500; i++) {
      var v = rows[i] ? rows[i][col] : null;
      if (v === null || v === undefined || v === "") continue;
      if (typeof v === "boolean") { if (!t) t = "INTEGER"; continue; }
      if (typeof v === "number") { if (t === "TEXT") continue; t = (t === "REAL" || !Number.isInteger(v)) ? "REAL" : "INTEGER"; continue; }
      return "TEXT";
    }
    return t || "TEXT";
  }
  function value(v) {
    if (v === undefined || v === null) return null;
    if (typeof v === "boolean") return v ? 1 : 0;
    if (typeof v === "number" || typeof v === "string") return v;
    if (v instanceof Date) return isNaN(v.getTime()) ? null : v.toISOString().slice(0, 10);
    return JSON.stringify(v);
  }
  function load(db, name, rows) {
    rows = rows || [];
    var cols = columnsOf(rows);
    if (!cols.length) cols = ["value"];
    db.run("DROP TABLE IF EXISTS " + quote(name));
    db.run("CREATE TABLE " + quote(name) + " (" + cols.map(function (c) { return quote(c) + " " + typeOf(rows, c); }).join(", ") + ")");
    var st = db.prepare("INSERT INTO " + quote(name) + " VALUES (" + cols.map(function () { return "?"; }).join(", ") + ")");
    db.run("BEGIN");
    try { rows.forEach(function (r) { st.run(cols.map(function (c) { return value(r ? r[c] : null); })); }); db.run("COMMIT"); }
    catch (e) { db.run("ROLLBACK"); throw e; }
    finally { st.free(); }
  }
  function wrap(db) {
    return {
      query: function (sql, params) {
        var out = [], st = db.prepare(sql);
        try { if (params) st.bind(params); while (st.step()) out.push(st.getAsObject()); } finally { st.free(); }
        return out;
      },
      run: function (sql, params) { db.run(sql, params); },
      add: function (name, rows) { load(db, name, rows); },
      tables: function () { return this.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").map(function (r) { return r.name; }); },
      close: function () { db.close(); }
    };
  }
  window.KitSql = {
    open: function (tables) {
      return engine().then(function (SQL) {
        var db = new SQL.Database();
        Object.keys(tables || {}).forEach(function (k) { load(db, k, tables[k]); });
        return wrap(db);
      });
    }
  };
})();
