/*
  StreamHub's built-in builder, run in a headless Edge tab (lib/WebBuild.psm1), so React and
  TypeScript apps build on a computer without Node.js or npm. esbuild (WebAssembly) bundles the
  project's src/ into one classic script (dist/app.js) and a stylesheet (dist/app.css) that also run
  from a page opened from disk; TypeScript checks the types. Only React, ReactDOM and the React JSX
  runtime are available as packages (vendor.js); anything else must be the project's own code.
  window.KitBuild.run({ entry, files: { "src/main.tsx": TEXT, ... }, typecheck }) returns
  { ok, outputs: { "dist/app.js": TEXT, ... }, errors: [{ file, line, column, text }], warnings, typeErrors }.
*/
(function () {
  "use strict";
  var unpackCache = {};
  function unpack(name) {
    if (unpackCache[name]) return unpackCache[name];
    var bin = atob(window[name]), bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    unpackCache[name] = new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"))).arrayBuffer();
    return unpackCache[name];
  }
  function unpackText(name) { return unpack(name).then(function (b) { return new TextDecoder().decode(b); }); }

  var started = null;
  function startEsbuild() {
    if (!started) started = unpack("__kitBuildWasm").then(function (b) { return WebAssembly.compile(b); }).then(function (m) { return esbuild.initialize({ wasmModule: m, worker: false }); });
    return started;
  }
  var vendor = null;
  function getVendor() { if (!vendor) vendor = unpackText("__kitBuildVendor").then(JSON.parse); return vendor; }
  var tsLoaded = null;
  function getTs() {
    if (!tsLoaded) tsLoaded = unpackText("__kitBuildTs").then(function (t) {
      var pack = JSON.parse(t);
      // TypeScript as a classic script defines a global "ts".
      (0, eval)(pack.code + "\n;window.ts = ts;");
      return { ts: window.ts, files: pack.files };
    });
    return tsLoaded;
  }

  var EXT = ["", ".tsx", ".ts", ".jsx", ".js", ".mjs", ".json", ".css", "/index.tsx", "/index.ts", "/index.jsx", "/index.js"];
  var PACKAGES = {
    "react": "/node_modules/react/index.js", "react/jsx-runtime": "/node_modules/react/jsx-runtime.js", "react/jsx-dev-runtime": "/node_modules/react/jsx-dev-runtime.js",
    "react-dom": "/node_modules/react-dom/index.js", "react-dom/client": "/node_modules/react-dom/client.js", "scheduler": "/node_modules/scheduler/index.js"
  };
  function dirOf(p) { return p.slice(0, p.lastIndexOf("/")) || "/"; }
  function join(dir, rel) {
    var parts = (dir + "/" + rel).split("/"), out = [];
    parts.forEach(function (x) { if (!x || x === ".") return; if (x === "..") out.pop(); else out.push(x); });
    return "/" + out.join("/");
  }
  function loaderOf(p) {
    var m = /\.([a-z0-9]+)$/i.exec(p), e = m ? m[1].toLowerCase() : "";
    if (/^(tsx|ts|jsx|js|json|css)$/.test(e)) return e === "mjs" ? "js" : e;
    if (e === "mjs" || e === "cjs") return "js";
    if (/^(png|jpe?g|gif|svg|webp|ico|woff2?|ttf|otf)$/.test(e)) return "dataurl";
    return "text";
  }

  function memoryPlugin(files, vend) {
    var has = function (p) { return Object.prototype.hasOwnProperty.call(files, p) || Object.prototype.hasOwnProperty.call(vend, p); };
    var find = function (base) { for (var i = 0; i < EXT.length; i++) if (has(base + EXT[i])) return base + EXT[i]; return null; };
    return {
      name: "streamhub-files",
      setup: function (b) {
        b.onResolve({ filter: /.*/ }, function (a) {
          if (a.kind === "entry-point") return { path: a.path, namespace: "mem" };
          var spec = a.path;
          if (/^(\.|\/)/.test(spec)) {
            var found = find(spec.charAt(0) === "/" ? join("", spec) : join(a.resolveDir || "/", spec));
            return found ? { path: found, namespace: "mem" } : { errors: [{ text: "Cannot find " + spec + " (from " + a.importer.replace(/^\//, "") + ")" }] };
          }
          if (PACKAGES[spec]) return { path: PACKAGES[spec], namespace: "mem" };
          return { errors: [{ text: "The package \"" + spec + "\" is not available here: the built-in builder has React, ReactDOM (react-dom/client) and the React JSX runtime only, because this computer has no npm. Write it as the project's own code, or use the UI kit." }] };
        });
        b.onLoad({ filter: /.*/, namespace: "mem" }, function (a) {
          var p = a.path, text = Object.prototype.hasOwnProperty.call(files, p) ? files[p] : vend[p];
          var l = loaderOf(p);
          if (l === "dataurl") return { contents: Uint8Array.from(atob(text), function (c) { return c.charCodeAt(0); }), loader: "dataurl", resolveDir: dirOf(p) };
          return { contents: text, loader: l, resolveDir: dirOf(p) };
        });
      }
    };
  }

  function typecheck(input) {
    return getTs().then(function (pack) {
      var ts = pack.ts, all = {};
      Object.keys(pack.files).forEach(function (k) { all[k] = pack.files[k]; });
      Object.keys(input.files).forEach(function (k) { if (!input.binary || !input.binary[k]) all["/" + k] = input.files[k]; });
      all["/src/__streamhub-env.d.ts"] = "declare module '*.css';\ndeclare module '*.svg' { const src: string; export default src; }\ndeclare module '*.png' { const src: string; export default src; }\ndeclare module '*.jpg' { const src: string; export default src; }\ndeclare module '*.json' { const value: any; export default value; }\n";
      var roots = Object.keys(all).filter(function (k) { return /^\/src\/.*\.(ts|tsx)$/.test(k) && !/\.d\.ts$/.test(k) || k === "/src/__streamhub-env.d.ts"; });
      var options = {
        target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler, jsx: ts.JsxEmit.ReactJSX,
        strict: true, noEmit: true, skipLibCheck: true, esModuleInterop: true, resolveJsonModule: true, allowImportingTsExtensions: true, isolatedModules: true,
        lib: ["lib.es2022.d.ts", "lib.dom.d.ts", "lib.dom.iterable.d.ts"], types: []
      };
      var host = {
        getSourceFile: function (n, lang) { var t = all[n]; return t === undefined ? undefined : ts.createSourceFile(n, t, lang, true); },
        getDefaultLibFileName: function () { return "/lib/lib.d.ts"; },
        writeFile: function () {}, getCurrentDirectory: function () { return "/"; }, getDirectories: function () { return []; },
        fileExists: function (n) { return Object.prototype.hasOwnProperty.call(all, n); }, readFile: function (n) { return all[n]; },
        directoryExists: function (d) { var pre = d.replace(/\/?$/, "/"); return Object.keys(all).some(function (k) { return k.indexOf(pre) === 0; }); },
        getCanonicalFileName: function (n) { return n; }, useCaseSensitiveFileNames: function () { return true; }, getNewLine: function () { return "\n"; }
      };
      var program = ts.createProgram(roots, options, host);
      return ts.getPreEmitDiagnostics(program).filter(function (d) { return !d.file || /^\/src\//.test(d.file.fileName); }).slice(0, 40).map(function (d) {
        var pos = d.file && d.start !== undefined ? d.file.getLineAndCharacterOfPosition(d.start) : null;
        return { file: d.file ? d.file.fileName.replace(/^\//, "") : "", line: pos ? pos.line + 1 : 0, column: pos ? pos.character + 1 : 0, text: "TS" + d.code + " " + ts.flattenDiagnosticMessageText(d.messageText, " ") };
      });
    });
  }

  function message(m) { return { file: m.location ? m.location.file.replace(/^(mem:)?\//, "") : "", line: m.location ? m.location.line : 0, column: m.location ? m.location.column + 1 : 0, text: m.text }; }

  function run(input) {
    var files = {};
    Object.keys(input.files).forEach(function (k) { files["/" + k] = input.files[k]; });
    var result = { ok: false, outputs: {}, errors: [], warnings: [], typeErrors: [] };
    return Promise.all([startEsbuild(), getVendor()]).then(function (r) {
      return esbuild.build({
        entryPoints: ["/" + input.entry], bundle: true, write: false, outdir: "/dist", entryNames: "app", format: "iife", platform: "browser", target: "es2020",
        jsx: "automatic", minify: !!input.minify, sourcemap: false, logLevel: "silent", charset: "utf8",
        define: { "process.env.NODE_ENV": "\"production\"" }, plugins: [memoryPlugin(files, r[1])]
      }).then(function (b) {
        b.outputFiles.forEach(function (f) { result.outputs[f.path.replace(/^\//, "")] = f.text; });
        result.warnings = b.warnings.map(message);
        result.ok = true;
      }, function (e) {
        result.errors = (e && e.errors ? e.errors : [{ text: String(e && e.message || e) }]).map(function (m) { return m.location !== undefined ? message(m) : { file: "", line: 0, column: 0, text: m.text }; });
      });
    }).then(function () {
      if (!input.typecheck) return result;
      return typecheck(input).then(function (t) { result.typeErrors = t; return result; }, function (e) { result.typeErrors = [{ file: "", line: 0, column: 0, text: "type check failed: " + (e && e.message || e) }]; return result; });
    });
  }

  window.KitBuild = { run: function (input) { return run(input).then(JSON.stringify); }, ready: true };
})();
