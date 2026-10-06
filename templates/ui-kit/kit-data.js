/*
  UI kit file readers for plain pages (no build step, works from file://): a file a person picks or
  drops (input type="file", the kit's drop zone) is read in the browser, nothing is uploaded.

    KitData.readFile(file)        -> Promise of one of:
      { kind: "table", sheets: [{ name, columns: [{ name, type }], rows: [{...}] }], rows }
          .csv .tsv .txt (delimited) .xlsx .xlsm; rows = the first sheet's rows
      { kind: "json", data }                    .json
      { kind: "document", blocks: [{ type: "heading", level, text } | { type: "paragraph", text, list }
          | { type: "table", rows: [[text]] }], text }                      .docx
      { kind: "slides", slides: [{ number, title, lines: [text], notes }], text }   .pptx
      { kind: "pdf", pages: [{ number, text }], text }                      .pdf (needs pdf.js, below)
      { kind: "text", text }                    anything else that is text
    KitData.parseCsv(text, { delimiter })  -> { columns, rows } (typed like the table above)
    KitData.readXlsx / readDocx / readPptx / readPdf(arrayBuffer)
    KitData.accept                  the extensions it reads, for <input accept="...">

  Values in a table are typed per column, the same rules the helper program uses for data/NAME.json:
  a column is a number, true/false or a date only when every value in it is one; numbers with a
  decimal comma are read when the file uses ; between values; dates come out as yyyy-MM-dd text;
  codes with a leading zero (007) stay text; empty cells are null.

  PDF: add the two pdf.js scripts before this one (pdf.js 3.11, Apache 2.0, see vendor/pdfjs):
    <script src="styles/kit/vendor/pdfjs/pdf.min.js"></script>
    <script src="styles/kit/vendor/pdfjs/pdf.worker.min.js"></script>
  The worker script runs on the page itself, which also works for pages opened from disk.
*/
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.KitData = api;
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var MISSING = /^(|null|NULL|N\/A|n\/a|NA|#N\/A)$/;

  /* ---- Text ------------------------------------------------------------------------------ */

  function decodeText(bytes) {
    // A BOM decides; else UTF-8 when the bytes are valid UTF-8, else Windows-1252.
    var b = new Uint8Array(bytes);
    if (b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) return new TextDecoder("utf-8").decode(b.subarray(3));
    if (b[0] === 0xff && b[1] === 0xfe) return new TextDecoder("utf-16le").decode(b.subarray(2));
    if (b[0] === 0xfe && b[1] === 0xff) return new TextDecoder("utf-16be").decode(b.subarray(2));
    try { return new TextDecoder("utf-8", { fatal: true }).decode(b); }
    catch (e) { return new TextDecoder("windows-1252").decode(b); }
  }

  /* ---- CSV and typed tables -------------------------------------------------------------- */

  function guessDelimiter(text) {
    var first = text.split("\n", 1)[0].replace(/"[^"]*"/g, "");
    var best = ",", most = 0;
    [",", ";", "\t", "|"].forEach(function (d) {
      var n = first.split(d).length - 1;
      if (n > most) { best = d; most = n; }
    });
    return best;
  }

  function splitCsv(text, delimiter) {
    // Rows of fields: quoted fields, "" inside quotes, line breaks inside quotes; blank lines skipped.
    var rows = [], row = [], field = "", i = 0, quoted = false, n = text.length, any = false;
    while (i < n) {
      var ch = text[i];
      if (quoted) {
        if (ch === '"') {
          if (text[i + 1] === '"') { field += '"'; i += 2; continue; }
          quoted = false; i++; continue;
        }
        field += ch; i++; continue;
      }
      if (ch === '"' && field === "") { quoted = true; any = true; i++; continue; }
      if (ch === delimiter) { row.push(field); field = ""; any = true; i++; continue; }
      if (ch === "\r" || ch === "\n") {
        if (ch === "\r" && text[i + 1] === "\n") i++;
        row.push(field);
        if (any || row.length > 1 || row[0] !== "") rows.push(row);
        row = []; field = ""; any = false; i++; continue;
      }
      field += ch; any = true; i++;
    }
    if (field !== "" || row.length || any) { row.push(field); rows.push(row); }
    return rows;
  }

  function columnNames(header, width) {
    var seen = {}, out = [];
    for (var i = 0; i < width; i++) {
      var name = String(header[i] == null ? "" : header[i]).trim() || "Column " + (i + 1);
      var base = name, k = 2;
      while (seen[name.toLowerCase()]) name = base + " " + k++;
      seen[name.toLowerCase()] = true;
      out.push(name);
    }
    return out;
  }

  var DOT = /^[-+]?(\d+|\d{1,3}(,\d{3})+)(\.\d+)?([eE][-+]?\d+)?$/;
  var COMMA = /^[-+]?(\d+|\d{1,3}(\.\d{3})+)(,\d+)?$/;
  var ISO = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2}))?)?$/;
  var DMY = /^(\d{1,2})([/.-])(\d{1,2})\2(\d{4})(?: (\d{1,2}):(\d{2})(?::(\d{2}))?)?$/;

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
        else {
          if (+m[1] > 12) dayFirst = true;
          if (+m[3] > 12) monthFirst = true;
          if (m[2] !== ".") dots = false;
        }
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
      else {
        m = DMY.exec(v); y = m[4]; h = m[5]; mi = m[6]; s = m[7];
        if (t.order === "dmy") { d = m[1]; mo = m[3]; } else { mo = m[1]; d = m[3]; }
      }
      var out = pad(y, 4) + "-" + pad(+mo) + "-" + pad(+d);
      if (h !== undefined) out += "T" + pad(+h) + ":" + mi + ":" + (s || "00");
      return out;
    }
    return v;
  }

  function toTable(rows, delimiter, name) {
    // Rows of text (first = header) as typed records.
    if (!rows.length) return { name: name || "", columns: [], rows: [] };
    var width = 0;
    rows.forEach(function (r) { if (r.length > width) width = r.length; });
    var names = columnNames(rows[0], width), types = [];
    for (var c = 0; c < width; c++) {
      var vals = [];
      for (var i = 1; i < rows.length; i++) vals.push(String(rows[i][c] == null ? "" : rows[i][c]).trim());
      types.push(columnType(vals, delimiter));
    }
    var records = [];
    for (var r = 1; r < rows.length; r++) {
      var o = {};
      for (var k = 0; k < width; k++) o[names[k]] = typedValue(String(rows[r][k] == null ? "" : rows[r][k]).trim(), types[k]);
      records.push(o);
    }
    return { name: name || "", columns: names.map(function (n, i) { return { name: n, type: types[i].type }; }), rows: records };
  }

  function parseCsv(text, options) {
    var delimiter = (options && options.delimiter) || guessDelimiter(text);
    var t = toTable(splitCsv(text, delimiter), delimiter);
    return { columns: t.columns, rows: t.rows };
  }

  /* ---- Zip (Office files are zip files of XML) --------------------------------------------- */

  function inflateRaw(bytes) {
    if (typeof DecompressionStream === "undefined") return Promise.reject(new Error("This browser cannot unzip files (no DecompressionStream)"));
    var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
    return new Response(stream).arrayBuffer().then(function (b) { return new Uint8Array(b); });
  }

  function readZip(buffer) {
    var b = new Uint8Array(buffer), v = new DataView(b.buffer, b.byteOffset, b.byteLength);
    var end = -1;
    for (var i = b.length - 22; i >= Math.max(0, b.length - 65557); i--) {
      if (v.getUint32(i, true) === 0x06054b50) { end = i; break; }
    }
    if (end < 0) throw new Error("Not a zip-based Office file (it may be an older .xls/.doc/.ppt, or password-protected)");
    var count = v.getUint16(end + 10, true), at = v.getUint32(end + 16, true), entries = {};
    for (var n = 0; n < count; n++) {
      if (v.getUint32(at, true) !== 0x02014b50) break;
      var method = v.getUint16(at + 10, true), size = v.getUint32(at + 20, true);
      var nameLen = v.getUint16(at + 28, true), extraLen = v.getUint16(at + 30, true), commentLen = v.getUint16(at + 32, true);
      var local = v.getUint32(at + 42, true);
      var name = new TextDecoder("utf-8").decode(b.subarray(at + 46, at + 46 + nameLen));
      entries[name] = { method: method, size: size, local: local };
      at += 46 + nameLen + extraLen + commentLen;
    }
    function bytesOf(name) {
      var e = entries[name];
      if (!e) return Promise.resolve(null);
      var start = e.local + 30 + v.getUint16(e.local + 26, true) + v.getUint16(e.local + 28, true);
      var data = b.subarray(start, start + e.size);
      if (e.method === 0) return Promise.resolve(data);
      if (e.method === 8) return inflateRaw(data);
      return Promise.reject(new Error("Unsupported compression in " + name));
    }
    return {
      names: Object.keys(entries),
      bytes: bytesOf,
      text: function (name) { return bytesOf(name).then(function (x) { return x ? new TextDecoder("utf-8").decode(x) : null; }); }
    };
  }

  /* ---- XML (the few Office parts read here, by pattern) ------------------------------------- */

  function unescapeXml(s) {
    return s.replace(/&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);/g, function (m, e) {
      if (e[0] === "#") return String.fromCodePoint(e[1] === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
      return { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" }[e];
    });
  }

  function attrs(tag) {
    var o = {}, re = /([\w:.-]+)\s*=\s*"([^"]*)"/g, m;
    while ((m = re.exec(tag))) { o[m[1]] = unescapeXml(m[2]); var local = m[1].split(":").pop(); if (!(local in o)) o[local] = o[m[1]]; }
    return o;
  }

  // Every element NAME (any namespace prefix): [{ attrs, inner }] (inner is "" for <NAME/>).
  function elements(xml, name) {
    var re = new RegExp("<(?:[\\w-]+:)?" + name + "\\b([^>]*?)(?:/>|>([\\s\\S]*?)</(?:[\\w-]+:)?" + name + ">)", "g"), out = [], m;
    while ((m = re.exec(xml))) out.push({ attrs: attrs(m[1]), inner: m[2] || "" });
    return out;
  }

  function textRuns(xml, tag) {
    // The text of <t> (or <a:t>/<w:t>) elements, with tabs and breaks.
    var re = new RegExp("<(?:[\\w-]+:)?" + tag + "\\b[^>]*?(?:/>|>([\\s\\S]*?)</(?:[\\w-]+:)?" + tag + ">)|<(?:[\\w-]+:)?(tab|br|cr)\\b[^>]*/>", "g"), out = "", m;
    while ((m = re.exec(xml))) {
      if (m[2]) out += m[2] === "tab" ? "\t" : "\n";
      else out += unescapeXml(m[1] || "");
    }
    return out;
  }

  function resolvePart(base, target) {
    if (target[0] === "/") return target.slice(1);
    var parts = (base ? base + "/" + target : target).split("/"), out = [];
    parts.forEach(function (p) { if (p === "..") out.pop(); else if (p && p !== ".") out.push(p); });
    return out.join("/");
  }

  function rels(zip, relsName, base) {
    return zip.text(relsName).then(function (x) {
      var map = {};
      if (x) elements(x, "Relationship").forEach(function (r) {
        if (r.attrs.TargetMode !== "External") map[r.attrs.Id] = { part: resolvePart(base, r.attrs.Target), type: r.attrs.Type || "" };
      });
      return map;
    });
  }

  /* ---- Excel ----------------------------------------------------------------------------- */

  function colIndex(ref) {
    var letters = (/^[A-Za-z]+/.exec(ref) || [""])[0].toUpperCase(), n = 0;
    for (var i = 0; i < letters.length; i++) n = n * 26 + (letters.charCodeAt(i) - 64);
    return n - 1;
  }

  function dateStyles(stylesXml) {
    var set = {}, custom = {};
    if (!stylesXml) return set;
    elements(stylesXml, "numFmt").forEach(function (f) {
      var code = (f.attrs.formatCode || "").replace(/"[^"]*"|\[[^\]]*\]|\\./g, "");
      custom[f.attrs.numFmtId] = /[dmyhs]/i.test(code) && !/^[#0.,%\s]*$/.test(code);
    });
    var xfs = elements(stylesXml, "cellXfs")[0];
    if (xfs) elements(xfs.inner, "xf").forEach(function (xf, i) {
      var id = +xf.attrs.numFmtId;
      if ((id >= 14 && id <= 22) || (id >= 45 && id <= 47) || custom[xf.attrs.numFmtId]) set[i] = true;
    });
    return set;
  }

  function serialToText(num, date1904) {
    var ms = Math.round((num + (date1904 ? 1462 : 0) - 25569) * 86400000);
    var d = new Date(ms), day = d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate());
    var time = pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes()) + ":" + pad(d.getUTCSeconds());
    if (num === Math.floor(num)) return day;
    if (num < 1) return time;
    return day + "T" + time;
  }

  function readXlsx(buffer) {
    var zip = readZip(buffer);
    return Promise.all([zip.text("xl/workbook.xml"), rels(zip, "xl/_rels/workbook.xml.rels", "xl"), zip.text("xl/sharedStrings.xml"), zip.text("xl/styles.xml")]).then(function (p) {
      var wb = p[0], map = p[1];
      if (!wb) throw new Error("No xl/workbook.xml: not an Excel workbook");
      var date1904 = /date1904\s*=\s*"(1|true)"/.test(wb);
      var shared = p[2] ? elements(p[2], "si").map(function (si) { return textRuns(si.inner.replace(/<(?:[\w-]+:)?rPh\b[\s\S]*?<\/(?:[\w-]+:)?rPh>/g, ""), "t"); }) : [];
      var dates = dateStyles(p[3]);
      var sheets = elements(wb, "sheet").filter(function (s) { return s.attrs.state !== "hidden" && s.attrs.state !== "veryHidden"; });
      return Promise.all(sheets.map(function (s) {
        var target = map[s.attrs["r:id"] || s.attrs.id];
        return target ? zip.text(target.part).then(function (x) { return { name: s.attrs.name, xml: x }; }) : null;
      })).then(function (list) {
        var out = [];
        list.forEach(function (sh) {
          if (!sh || !sh.xml) return;
          var rows = [];
          elements(sh.xml, "row").forEach(function (row) {
            var cells = [], max = -1;
            elements(row.inner, "c").forEach(function (c) {
              var t = c.attrs.t || "", vm = /<(?:[\w-]+:)?v\b[^>]*>([\s\S]*?)<\/(?:[\w-]+:)?v>/.exec(c.inner), v = vm ? unescapeXml(vm[1]) : "";
              var val;
              if (t === "s") val = shared[+v] || "";
              else if (t === "inlineStr") val = textRuns(c.inner, "t");
              else if (t === "b") val = v === "1" ? "TRUE" : "FALSE";
              else if (t === "e") val = "";
              else val = v;
              if (val !== "" && (t === "" || t === "n") && c.attrs.s && dates[+c.attrs.s] && !isNaN(+val)) val = serialToText(+val, date1904);
              if (val === "") return;
              var i = c.attrs.r ? colIndex(c.attrs.r) : max + 1;
              cells[i] = val;
              if (i > max) max = i;
            });
            if (max < 0) return;
            var r = [];
            for (var k = 0; k <= max; k++) r.push(cells[k] == null ? "" : cells[k]);
            rows.push(r);
          });
          if (rows.length) out.push(toTable(rows, ",", sh.name));
        });
        return { kind: "table", sheets: out, rows: out.length ? out[0].rows : [] };
      });
    });
  }

  /* ---- Word ------------------------------------------------------------------------------ */

  function readDocx(buffer) {
    var zip = readZip(buffer);
    return Promise.all([zip.text("word/document.xml"), zip.text("word/styles.xml")]).then(function (p) {
      if (!p[0]) throw new Error("No word/document.xml: not a Word document");
      var levels = {};
      if (p[1]) elements(p[1], "style").forEach(function (s) {
        var nm = /<(?:[\w-]+:)?name\b[^>]*?val="([^"]*)"/.exec(s.inner), name = nm ? nm[1].toLowerCase() : "";
        var m = /^heading (\d)$/.exec(name);
        if (m) levels[s.attrs.styleId] = +m[1];
        else if (name === "title") levels[s.attrs.styleId] = 1;
      });
      var body = (/<(?:[\w-]+:)?body\b[^>]*>([\s\S]*)<\/(?:[\w-]+:)?body>/.exec(p[0]) || [, p[0]])[1];
      var blocks = [], re = /<(?:[\w-]+:)?tbl\b[\s\S]*?<\/(?:[\w-]+:)?tbl>|<(?:[\w-]+:)?p\b[^>]*\/>|<(?:[\w-]+:)?p\b[^>]*>[\s\S]*?<\/(?:[\w-]+:)?p>/g, m;
      // Tab stops in the paragraph properties and field codes or deleted text are not text.
      function paraText(x) { return textRuns(x.replace(/<(?:[\w-]+:)?(pPr|instrText|delText)\b[\s\S]*?<\/(?:[\w-]+:)?\1>/g, ""), "t"); }
      while ((m = re.exec(body))) {
        var x = m[0];
        if (/^<(?:[\w-]+:)?tbl\b/.test(x)) {
          var rows = elements(x, "tr").map(function (tr) {
            return elements(tr.inner, "tc").map(function (tc) { return elements(tc.inner, "p").map(function (pp) { return paraText(pp.inner); }).join("\n").trim(); });
          });
          blocks.push({ type: "table", rows: rows });
          continue;
        }
        var text = paraText(x).trim();
        if (!text) continue;
        var sm = /<(?:[\w-]+:)?pStyle\b[^>]*?val="([^"]*)"/.exec(x), style = sm ? sm[1] : "";
        var level = levels[style] || (/^Heading(\d)$/i.exec(style) || [])[1];
        if (level) blocks.push({ type: "heading", level: +level, text: text });
        else blocks.push({ type: "paragraph", text: text, list: /<(?:[\w-]+:)?numPr\b/.test(x) });
      }
      var plain = blocks.map(function (b) { return b.type === "table" ? b.rows.map(function (r) { return r.join("\t"); }).join("\n") : b.text; }).join("\n\n");
      return { kind: "document", blocks: blocks, text: plain };
    });
  }

  /* ---- PowerPoint ------------------------------------------------------------------------ */

  function shapeLines(xml) {
    var lines = [], title = "";
    elements(xml, "sp").forEach(function (sp) {
      var ph = /<(?:[\w-]+:)?ph\b[^>]*?type="([^"]*)"/.exec(sp.inner), type = ph ? ph[1] : "";
      if (type === "sldNum" || type === "dt" || type === "ftr" || type === "sldImg") return;
      var paras = elements(sp.inner, "p").map(function (pp) { return textRuns(pp.inner, "t").trim(); }).filter(Boolean);
      if (!paras.length) return;
      if ((type === "title" || type === "ctrTitle") && !title) title = paras.join(" ");
      else lines.push.apply(lines, paras);
    });
    return { title: title, lines: lines };
  }

  function readPptx(buffer) {
    var zip = readZip(buffer);
    return Promise.all([zip.text("ppt/presentation.xml"), rels(zip, "ppt/_rels/presentation.xml.rels", "ppt")]).then(function (p) {
      if (!p[0]) throw new Error("No ppt/presentation.xml: not a PowerPoint file");
      var ids = elements(p[0], "sldId").map(function (s) { return p[1][s.attrs["r:id"] || s.attrs.id]; }).filter(Boolean);
      return Promise.all(ids.map(function (t, i) {
        var dir = t.part.slice(0, t.part.lastIndexOf("/")), file = t.part.slice(t.part.lastIndexOf("/") + 1);
        return Promise.all([zip.text(t.part), rels(zip, dir + "/_rels/" + file + ".rels", dir)]).then(function (q) {
          var notesRel = Object.keys(q[1]).map(function (k) { return q[1][k]; }).filter(function (r) { return /notesSlide$/.test(r.type); })[0];
          return (notesRel ? zip.text(notesRel.part) : Promise.resolve(null)).then(function (nx) {
            var s = shapeLines(q[0] || "");
            var notes = nx ? shapeLines(nx).lines.join("\n") : "";
            return { number: i + 1, title: s.title, lines: s.lines, notes: notes };
          });
        });
      })).then(function (slides) {
        var text = slides.map(function (s) { return ["Slide " + s.number + (s.title ? ": " + s.title : "")].concat(s.lines).join("\n"); }).join("\n\n");
        return { kind: "slides", slides: slides, text: text };
      });
    });
  }

  /* ---- PDF (pdf.js) ---------------------------------------------------------------------- */

  var scriptBase = (function () {
    try { var s = document.currentScript && document.currentScript.src; return s ? s.slice(0, s.lastIndexOf("/") + 1) : ""; } catch (e) { return ""; }
  })();

  function readPdf(buffer) {
    var lib = typeof window !== "undefined" ? window.pdfjsLib || window["pdfjs-dist/build/pdf"] : null;
    if (!lib) return Promise.reject(new Error("Reading PDF files needs pdf.js: add <script src=\"styles/kit/vendor/pdfjs/pdf.min.js\"></script> and pdf.worker.min.js before kit-data.js"));
    // With pdf.worker.min.js loaded as a script, pdf.js runs it on the page (also from file://).
    if (!window.pdfjsWorker && !lib.GlobalWorkerOptions.workerSrc && scriptBase) lib.GlobalWorkerOptions.workerSrc = scriptBase + "vendor/pdfjs/pdf.worker.min.js";
    return lib.getDocument({ data: new Uint8Array(buffer), isEvalSupported: false }).promise.then(function (doc) {
      var jobs = [];
      for (var i = 1; i <= doc.numPages; i++) jobs.push(doc.getPage(i).then(function (page) {
        return page.getTextContent().then(function (tc) {
          var text = "";
          tc.items.forEach(function (it) { if (typeof it.str === "string") text += it.str + (it.hasEOL ? "\n" : ""); });
          return { number: page.pageNumber, text: text.replace(/[ \t]+\n/g, "\n").trim() };
        });
      }));
      return Promise.all(jobs).then(function (pages) {
        doc.destroy();
        return { kind: "pdf", pages: pages, text: pages.map(function (p) { return p.text; }).join("\n\n") };
      });
    });
  }

  /* ---- Any file -------------------------------------------------------------------------- */

  function readBuffer(file) {
    if (file.arrayBuffer) return file.arrayBuffer();
    return new Promise(function (ok, fail) {
      var r = new FileReader();
      r.onload = function () { ok(r.result); };
      r.onerror = function () { fail(r.error); };
      r.readAsArrayBuffer(file);
    });
  }

  function extension(name) { var m = /\.([^.]+)$/.exec(name || ""); return m ? m[1].toLowerCase() : ""; }

  function readFile(file) {
    var ext = extension(file.name);
    return readBuffer(file).then(function (buf) {
      switch (ext) {
        case "xlsx": case "xlsm": return readXlsx(buf);
        case "docx": case "docm": return readDocx(buf);
        case "pptx": case "pptm": return readPptx(buf);
        case "pdf": return readPdf(buf);
        case "xls": case "doc": case "ppt": throw new Error("." + ext + " is an older Office format: save it as ." + ext + "x first");
      }
      var text = decodeText(buf);
      if (ext === "json") return { kind: "json", data: JSON.parse(text) };
      if (ext === "csv" || ext === "tsv" || (ext === "txt" && /[,;\t|]/.test(text.split("\n", 1)[0]))) {
        var delimiter = ext === "tsv" ? "\t" : guessDelimiter(text);
        var t = toTable(splitCsv(text, delimiter), delimiter, file.name);
        return { kind: "table", sheets: [t], rows: t.rows };
      }
      return { kind: "text", text: text };
    });
  }

  return {
    accept: ".csv,.tsv,.txt,.json,.xlsx,.xlsm,.docx,.pptx,.pdf",
    readFile: readFile, parseCsv: parseCsv, readXlsx: readXlsx, readDocx: readDocx, readPptx: readPptx, readPdf: readPdf,
    _internal: { splitCsv: splitCsv, columnType: columnType, readZip: readZip, decodeText: decodeText, serialToText: serialToText }
  };
});
