/*
  UI kit: Python in the page, through Pyodide (Mozilla Public License 2.0, vendor/pyodide/: Python's
  standard library only, no extra packages). It loads its parts from vendor/pyodide/, which a page
  opened from disk cannot do: it works when the page is served (StreamHub: Open app, or any web server).
    <script src="styles/kit/kit-python.js"></script>
  KitPython.run("import statistics\nstatistics.median([r['amount'] for r in sales])", { data: { sales: rows } })
    .then(function (r) { r.result; r.output; });
  data: lists or objects given to Python as Python lists and dicts under those names. The result is
  the value of the last line (lists, dicts, numbers and text come back as JavaScript values); output is
  what the code printed. The first call takes a few seconds (the engine starts once per page).
*/
(function () {
  "use strict";
  var here = (document.currentScript && document.currentScript.src || "").replace(/[^/]*$/, "");
  var base = here + "vendor/pyodide/";
  var ready = null;
  function engine() {
    if (location.protocol === "file:") return Promise.reject(new Error("Python in the page works when the page is served (StreamHub: Open app), not when it is opened from disk"));
    if (!ready) {
      ready = new Promise(function (resolve, reject) {
        var s = document.createElement("script");
        s.src = base + "pyodide.js";
        s.onload = function () { window.loadPyodide({ indexURL: base }).then(resolve, reject); };
        s.onerror = function () { reject(new Error("could not load " + base + "pyodide.js")); };
        document.head.appendChild(s);
      });
    }
    return ready;
  }
  function toJs(v) {
    if (v && typeof v.toJs === "function") { var j = v.toJs({ dict_converter: Object.fromEntries }); if (v.destroy) v.destroy(); return j; }
    return v;
  }
  window.KitPython = {
    ready: function () { return engine().then(function () { return true; }); },
    run: function (code, opts) {
      opts = opts || {};
      return engine().then(function (py) {
        var out = [];
        py.setStdout({ batched: function (t) { out.push(t); } });
        py.setStderr({ batched: function (t) { out.push(t); } });
        var data = opts.data || {};
        Object.keys(data).forEach(function (k) { py.globals.set(k, py.toPy(data[k])); });
        return py.runPythonAsync(String(code)).then(function (r) { return { result: toJs(r), output: out.join("\n") }; });
      });
    }
  };
})();
