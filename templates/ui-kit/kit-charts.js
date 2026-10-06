/*
  UI kit charts for plain pages (no build step, no library, works from file://): bar, line, area,
  ring, gauge, heatmap and sparkline, drawn as SVG on the kit's tokens (--kit-chart-1..6).
  Design adapted from bklit-ui chart components (MIT licence, see LICENSE-bklit-ui.txt):
  dashed grid, rounded bars, fading area fill, hover highlight with tooltip, legend, grow-in.

  Declarative: <div class="kit-chart" data-kit-chart="bar" data-kit-data='{"labels":[...],
  "series":[{"name":"A","values":[...]}]}' aria-label="What the chart shows"></div>
  From code: KitCharts.bar(element, data). Every chart also writes a hidden data table for
  screen readers, and redraws when its box changes size.
*/
(function () {
  "use strict";
  var NS = "http://www.w3.org/2000/svg";
  var reduce = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;

  function svgEl(tag, attrs, parent) {
    var e = document.createElementNS(NS, tag);
    for (var k in attrs) if (attrs[k] !== undefined && attrs[k] !== null) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  function color(i) { return "var(--kit-chart-" + ((i % 6) + 1) + ")"; }
  function fmt(v, opts) {
    if (opts && typeof opts.format === "function") return opts.format(v);
    var n = Number(v);
    if (Math.abs(n) >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
    if (Math.abs(n) >= 1e4) return (n / 1e3).toFixed(1).replace(/\.0$/, "") + "k";
    return n.toLocaleString(undefined, { maximumFractionDigits: 2 }) + ((opts && opts.unit) || "");
  }
  // Round axis steps: 1, 2 or 5 times a power of ten.
  function niceMax(max, ticks) {
    if (max <= 0) return { max: 1, step: 1 };
    var raw = max / ticks, p = Math.pow(10, Math.floor(Math.log10(raw))), m = raw / p;
    var step = (m <= 1 ? 1 : m <= 2 ? 2 : m <= 5 ? 5 : 10) * p;
    return { max: Math.ceil(max / step) * step, step: step };
  }
  function clear(host) {
    while (host.firstChild) host.removeChild(host.firstChild);
    host.classList.add("kit-chart");
  }
  // The data as a table, for screen readers (the SVG itself is one image with a summary).
  function dataTable(host, head, rows) {
    var t = document.createElement("table");
    t.className = "kit-chart__table";
    var tr = t.insertRow();
    head.forEach(function (h) { var th = document.createElement("th"); th.textContent = h; tr.appendChild(th); });
    rows.forEach(function (r) { var row = t.insertRow(); r.forEach(function (c) { row.insertCell().textContent = c; }); });
    host.appendChild(t);
  }
  function legend(host, names, onHover) {
    if (names.length < 2) return;
    var ul = document.createElement("ul");
    ul.className = "kit-chart__legend";
    names.forEach(function (n, i) {
      var li = document.createElement("li");
      li.innerHTML = '<span class="kit-chart__swatch" style="background:' + color(i) + '"></span>';
      li.appendChild(document.createTextNode(n));
      li.addEventListener("mouseenter", function () { onHover(i); });
      li.addEventListener("mouseleave", function () { onHover(-1); });
      ul.appendChild(li);
    });
    host.appendChild(ul);
  }
  function tooltip(host) {
    var tip = document.createElement("div");
    tip.className = "kit-chart__tip";
    tip.hidden = true;
    host.appendChild(tip);
    return {
      show: function (html, x, y) {
        tip.innerHTML = html;
        tip.hidden = false;
        var w = tip.offsetWidth, hw = host.clientWidth;
        tip.style.left = Math.max(0, Math.min(hw - w, x - w / 2)) + "px";
        tip.style.top = Math.max(0, y - tip.offsetHeight - 10) + "px";
      },
      hide: function () { tip.hidden = true; }
    };
  }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function size(host, h) { return { w: Math.max(200, host.clientWidth || 600), h: h || Number(host.getAttribute("data-kit-height")) || 260 }; }
  function frame(host, s, label) {
    return svgEl("svg", { width: s.w, height: s.h, viewBox: "0 0 " + s.w + " " + s.h, role: "img", "aria-label": label || host.getAttribute("aria-label") || "Chart", class: "kit-chart__svg" }, host);
  }
  // Dashed horizontal grid with value labels (left).
  function grid(svg, s, pad, scale, opts) {
    var g = svgEl("g", { class: "kit-chart__grid" }, svg);
    for (var v = 0; v <= scale.max + 1e-9; v += scale.step) {
      var y = pad.t + (s.h - pad.t - pad.b) * (1 - v / scale.max);
      svgEl("line", { x1: pad.l, x2: s.w - pad.r, y1: y, y2: y, "stroke-dasharray": v === 0 ? null : "4 4", class: v === 0 ? "kit-chart__base" : "kit-chart__line" }, g);
      svgEl("text", { x: pad.l - 8, y: y + 4, "text-anchor": "end", class: "kit-chart__label" }, g).textContent = fmt(v, opts);
    }
  }
  // Show every n-th label along an axis so they do not overlap (about 7px per character).
  function labelStep(labels, room) {
    var widest = Math.max.apply(null, [1].concat(labels.map(function (l) { return String(l).length; })));
    return Math.max(1, Math.ceil((labels.length * (widest * 7 + 10)) / Math.max(1, room)));
  }
  function series(data) { return (data.series || []).map(function (sr) { return { name: sr.name || "", values: (sr.values || []).map(Number) }; }); }

  // Bar chart: grouped bars per label; data.horizontal for bars to the right.
  function bar(host, data) {
    clear(host);
    var sr = series(data), labels = data.labels || [], s = size(host), horizontal = !!data.horizontal;
    var max = Math.max.apply(null, [0].concat.apply([], sr.map(function (x) { return x.values; })));
    var scale = niceMax(max, 4);
    var tip = null, bars = [];
    var svg = frame(host, s, data.title);
    var pad = horizontal ? { t: 8, r: 16, b: 24, l: 96 } : { t: 12, r: 12, b: 28, l: 44 };
    var plotW = s.w - pad.l - pad.r, plotH = s.h - pad.t - pad.b;
    if (!horizontal) grid(svg, s, pad, scale, data);
    var band = (horizontal ? plotH : plotW) / Math.max(1, labels.length);
    var lstep = horizontal ? 1 : labelStep(labels, plotW);
    var inner = band * 0.72, bw = Math.max(2, inner / Math.max(1, sr.length) - 2);
    labels.forEach(function (lab, li) {
      var start = (horizontal ? pad.t : pad.l) + li * band + (band - inner) / 2;
      sr.forEach(function (x, si) {
        var v = x.values[li] || 0, len = (horizontal ? plotW : plotH) * (v / scale.max);
        var r = Math.min(bw / 2, 6), a;
        if (horizontal) a = { x: pad.l, y: start + si * (bw + 2), width: Math.max(0, len), height: bw };
        else a = { x: start + si * (bw + 2), y: pad.t + plotH - len, width: bw, height: Math.max(0, len) };
        var rect = svgEl("rect", { x: a.x, y: a.y, width: a.width, height: a.height, rx: r, fill: color(si), class: "kit-chart__bar" }, svg);
        if (!reduce) rect.style.animation = (horizontal ? "kit-grow-x" : "kit-grow-y") + " 520ms cubic-bezier(0.22, 1, 0.36, 1) both";
        if (!reduce) rect.style.transformOrigin = horizontal ? (pad.l + "px 0") : ("0 " + (pad.t + plotH) + "px");
        rect.addEventListener("mouseenter", function () {
          bars.forEach(function (b) { b.el.classList.toggle("is-faded", b.el !== rect); });
          var box = rect.getBBox();
          tip.show("<strong>" + esc(lab) + "</strong><br>" + (x.name ? esc(x.name) + ": " : "") + esc(fmt(v, data)), box.x + box.width / 2, horizontal ? box.y : box.y);
        });
        rect.addEventListener("mouseleave", function () { bars.forEach(function (b) { b.el.classList.remove("is-faded"); }); tip.hide(); });
        bars.push({ el: rect, s: si });
      });
      if (li % lstep) return;
      var t = horizontal
        ? svgEl("text", { x: pad.l - 8, y: start + inner / 2 + 4, "text-anchor": "end", class: "kit-chart__label" }, svg)
        : svgEl("text", { x: start + inner / 2, y: s.h - 8, "text-anchor": "middle", class: "kit-chart__label" }, svg);
      t.textContent = lab;
    });
    tip = tooltip(host);
    legend(host, sr.map(function (x) { return x.name; }), function (i) { bars.forEach(function (b) { b.el.classList.toggle("is-faded", i >= 0 && b.s !== i); }); });
    dataTable(host, [""].concat(sr.map(function (x) { return x.name || "Value"; })), labels.map(function (l, li) { return [l].concat(sr.map(function (x) { return fmt(x.values[li] || 0, data); })); }));
  }

  // Line chart (data.area for a fading fill under each line).
  function line(host, data, area) {
    clear(host);
    var sr = series(data), labels = data.labels || [], s = size(host);
    var all = [].concat.apply([], sr.map(function (x) { return x.values; }));
    var scale = niceMax(Math.max.apply(null, [0].concat(all)), 4);
    var svg = frame(host, s, data.title);
    var pad = { t: 12, r: 16, b: 28, l: 44 }, plotW = s.w - pad.l - pad.r, plotH = s.h - pad.t - pad.b;
    grid(svg, s, pad, scale, data);
    var px = function (i) { return pad.l + (labels.length < 2 ? plotW / 2 : (plotW * i) / (labels.length - 1)); };
    var py = function (v) { return pad.t + plotH * (1 - v / scale.max); };
    var defs = svgEl("defs", {}, svg), paths = [];
    var uid = "k" + Math.random().toString(36).slice(2, 8);
    sr.forEach(function (x, si) {
      var pts = x.values.map(function (v, i) { return [px(i), py(v)]; });
      var d = pts.map(function (p, i) { return (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1); }).join(" ");
      if (area || data.area) {
        var gid = uid + "a" + si;
        var lg = svgEl("linearGradient", { id: gid, x1: 0, y1: 0, x2: 0, y2: 1 }, defs);
        svgEl("stop", { offset: "0%", "stop-color": color(si), "stop-opacity": 0.32 }, lg);
        svgEl("stop", { offset: "100%", "stop-color": color(si), "stop-opacity": 0 }, lg);
        svgEl("path", { d: d + " L" + pts[pts.length - 1][0] + " " + (pad.t + plotH) + " L" + pts[0][0] + " " + (pad.t + plotH) + " Z", fill: "url(#" + gid + ")", class: "kit-chart__area" }, svg);
      }
      var p = svgEl("path", { d: d, fill: "none", stroke: color(si), "stroke-width": 2.25, "stroke-linejoin": "round", "stroke-linecap": "round", class: "kit-chart__path" }, svg);
      if (!reduce) { var L = p.getTotalLength(); p.style.strokeDasharray = L; p.style.strokeDashoffset = L; p.style.animation = "kit-draw 700ms cubic-bezier(0.22, 1, 0.36, 1) forwards"; }
      paths.push(p);
    });
    var lstep = labelStep(labels, plotW);
    labels.forEach(function (lab, i) {
      if (i % lstep) return;
      svgEl("text", { x: px(i), y: s.h - 8, "text-anchor": "middle", class: "kit-chart__label" }, svg).textContent = lab;
    });
    // Hover: a guide line, a dot per series and the values at that point.
    var guide = svgEl("line", { y1: pad.t, y2: pad.t + plotH, class: "kit-chart__guide", visibility: "hidden" }, svg);
    var dots = sr.map(function (x, si) { return svgEl("circle", { r: 4, fill: color(si), class: "kit-chart__dot", visibility: "hidden" }, svg); });
    var tip = tooltip(host);
    var hit = svgEl("rect", { x: pad.l, y: pad.t, width: plotW, height: plotH, fill: "transparent" }, svg);
    hit.addEventListener("mousemove", function (e) {
      var r = svg.getBoundingClientRect(), x = (e.clientX - r.left) * (s.w / r.width);
      var i = Math.max(0, Math.min(labels.length - 1, Math.round(((x - pad.l) / plotW) * (labels.length - 1))));
      guide.setAttribute("x1", px(i)); guide.setAttribute("x2", px(i)); guide.setAttribute("visibility", "visible");
      var html = "<strong>" + esc(labels[i]) + "</strong>";
      sr.forEach(function (x, si) {
        dots[si].setAttribute("cx", px(i)); dots[si].setAttribute("cy", py(x.values[i] || 0)); dots[si].setAttribute("visibility", "visible");
        html += "<br>" + (x.name ? esc(x.name) + ": " : "") + esc(fmt(x.values[i] || 0, data));
      });
      tip.show(html, px(i) * (r.width / s.w), Math.min.apply(null, sr.map(function (x) { return py(x.values[i] || 0); })) * (r.height / s.h));
    });
    hit.addEventListener("mouseleave", function () { guide.setAttribute("visibility", "hidden"); dots.forEach(function (d) { d.setAttribute("visibility", "hidden"); }); tip.hide(); });
    legend(host, sr.map(function (x) { return x.name; }), function (i) { paths.forEach(function (p, pi) { p.classList.toggle("is-faded", i >= 0 && pi !== i); }); });
    dataTable(host, [""].concat(sr.map(function (x) { return x.name || "Value"; })), labels.map(function (l, li) { return [l].concat(sr.map(function (x) { return fmt(x.values[li] || 0, data); })); }));
  }

  // Ring (donut): data.items [{ label, value }]; data.center for the text in the middle.
  function ring(host, data) {
    clear(host);
    var items = (data.items || []).map(function (it) { return { label: it.label, value: Number(it.value) || 0 }; });
    var total = items.reduce(function (a, b) { return a + b.value; }, 0) || 1;
    var s = size(host, Number(host.getAttribute("data-kit-height")) || 220), cx = s.h / 2, cy = s.h / 2, R = s.h / 2 - 8, w = Math.max(10, R * 0.22);
    var svg = frame(host, { w: s.h, h: s.h }, data.title), tip = tooltip(host), arcs = [];
    var a0 = -Math.PI / 2, gap = items.length > 1 ? 0.025 : 0;
    items.forEach(function (it, i) {
      var a1 = a0 + (it.value / total) * Math.PI * 2;
      var s0 = a0 + gap / 2, s1 = Math.max(s0 + 0.001, a1 - gap / 2), r = R - w / 2;
      var large = s1 - s0 > Math.PI ? 1 : 0;
      var d = "M" + (cx + r * Math.cos(s0)) + " " + (cy + r * Math.sin(s0)) + " A" + r + " " + r + " 0 " + large + " 1 " + (cx + r * Math.cos(s1)) + " " + (cy + r * Math.sin(s1));
      var p = svgEl("path", { d: d, fill: "none", stroke: color(i), "stroke-width": w, "stroke-linecap": "butt", class: "kit-chart__arc" }, svg);
      p.addEventListener("mouseenter", function () {
        arcs.forEach(function (x) { x.classList.toggle("is-faded", x !== p); });
        tip.show("<strong>" + esc(it.label) + "</strong><br>" + esc(fmt(it.value, data)) + " (" + Math.round((it.value / total) * 100) + "%)", cx, cy - R / 3);
      });
      p.addEventListener("mouseleave", function () { arcs.forEach(function (x) { x.classList.remove("is-faded"); }); tip.hide(); });
      arcs.push(p);
      a0 = a1;
    });
    if (data.center !== undefined) svgEl("text", { x: cx, y: cy + 6, "text-anchor": "middle", class: "kit-chart__center" }, svg).textContent = data.center;
    legend(host, items.map(function (it) { return it.label; }), function (i) { arcs.forEach(function (x, xi) { x.classList.toggle("is-faded", i >= 0 && xi !== i); }); });
    dataTable(host, ["", "Value", "Share"], items.map(function (it) { return [it.label, fmt(it.value, data), Math.round((it.value / total) * 100) + "%"]; }));
  }

  // Gauge: data.value of data.max (default 100), with data.label under the number.
  function gauge(host, data) {
    clear(host);
    var max = Number(data.max) || 100, v = Math.max(0, Math.min(max, Number(data.value) || 0));
    var W = 220, H = 130, cx = W / 2, cy = H - 14, R = 92, w = 14;
    var svg = frame(host, { w: W, h: H }, data.title || (fmt(v, data) + " of " + fmt(max, data)));
    var arc = function (f) { var a = Math.PI * (1 - f); return (cx + R * Math.cos(a)) + " " + (cy - R * Math.sin(a)); };
    svgEl("path", { d: "M" + arc(0) + " A" + R + " " + R + " 0 0 1 " + arc(1), fill: "none", stroke: "var(--kit-surface-2)", "stroke-width": w, "stroke-linecap": "round" }, svg);
    var f = v / max;
    if (f > 0) {
      var p = svgEl("path", { d: "M" + arc(0) + " A" + R + " " + R + " 0 0 1 " + arc(f), fill: "none", stroke: data.color || color(0), "stroke-width": w, "stroke-linecap": "round" }, svg);
      if (!reduce) { var L = p.getTotalLength(); p.style.strokeDasharray = L; p.style.strokeDashoffset = L; p.style.animation = "kit-draw 800ms cubic-bezier(0.22, 1, 0.36, 1) forwards"; }
    }
    svgEl("text", { x: cx, y: cy - 22, "text-anchor": "middle", class: "kit-chart__center" }, svg).textContent = fmt(v, data);
    if (data.label) svgEl("text", { x: cx, y: cy - 2, "text-anchor": "middle", class: "kit-chart__label" }, svg).textContent = data.label;
    dataTable(host, ["Value", "Of"], [[fmt(v, data), fmt(max, data)]]);
  }

  // Heatmap: data.rows (labels), data.cols (labels), data.values[row][col].
  function heatmap(host, data) {
    clear(host);
    var rows = data.rows || [], cols = data.cols || [], vals = data.values || [];
    var max = Math.max.apply(null, [1].concat.apply([], vals.map(function (r) { return r.map(Number); })));
    var s = size(host), pad = { t: 22, r: 8, b: 8, l: 64 };
    var cw = Math.max(8, (s.w - pad.l - pad.r) / Math.max(1, cols.length)), ch = Math.min(28, Math.max(10, cw)), h = pad.t + ch * rows.length + pad.b;
    var svg = frame(host, { w: s.w, h: h }, data.title), tip = tooltip(host);
    cols.forEach(function (c, ci) { if (cols.length <= 31 || ci % Math.ceil(cols.length / 16) === 0) svgEl("text", { x: pad.l + ci * cw + cw / 2, y: 14, "text-anchor": "middle", class: "kit-chart__label" }, svg).textContent = c; });
    rows.forEach(function (r, ri) {
      svgEl("text", { x: pad.l - 8, y: pad.t + ri * ch + ch / 2 + 4, "text-anchor": "end", class: "kit-chart__label" }, svg).textContent = r;
      cols.forEach(function (c, ci) {
        var v = Number((vals[ri] || [])[ci]) || 0;
        var cell = svgEl("rect", { x: pad.l + ci * cw + 1.5, y: pad.t + ri * ch + 1.5, width: cw - 3, height: ch - 3, rx: 3, fill: v ? color(0) : "var(--kit-surface-2)", "fill-opacity": v ? 0.18 + 0.82 * (v / max) : 1, class: "kit-chart__cell" }, svg);
        cell.addEventListener("mouseenter", function () { tip.show("<strong>" + esc(r) + ", " + esc(c) + "</strong><br>" + esc(fmt(v, data)), pad.l + ci * cw + cw / 2, pad.t + ri * ch); });
        cell.addEventListener("mouseleave", function () { tip.hide(); });
      });
    });
    dataTable(host, [""].concat(cols), rows.map(function (r, ri) { return [r].concat(cols.map(function (c, ci) { return fmt(Number((vals[ri] || [])[ci]) || 0, data); })); }));
  }

  // Sparkline: a small line without axes, for tables and key figures (data.values).
  function sparkline(host, data) {
    clear(host);
    host.classList.add("kit-chart--spark");
    var v = (data.values || []).map(Number), W = Number(host.getAttribute("data-kit-width")) || 96, H = Number(host.getAttribute("data-kit-height")) || 28;
    var lo = Math.min.apply(null, v), hi = Math.max.apply(null, v), span = hi - lo || 1;
    var svg = frame(host, { w: W, h: H }, data.title || ("Trend from " + fmt(v[0], data) + " to " + fmt(v[v.length - 1], data)));
    var d = v.map(function (x, i) { return (i ? "L" : "M") + ((W - 4) * i / Math.max(1, v.length - 1) + 2).toFixed(1) + " " + (H - 3 - (H - 6) * (x - lo) / span).toFixed(1); }).join(" ");
    svgEl("path", { d: d, fill: "none", stroke: data.color || color(0), "stroke-width": 1.75, "stroke-linejoin": "round", "stroke-linecap": "round" }, svg);
  }

  var kinds = { bar: bar, line: function (h, d) { line(h, d, false); }, area: function (h, d) { line(h, d, true); }, ring: ring, gauge: gauge, heatmap: heatmap, sparkline: sparkline };
  function render(host, kind, data) {
    var fn = kinds[kind];
    if (!fn) return;
    host.__kitChart = { kind: kind, data: data };
    fn(host, data);
  }
  // Redraw when the box changes width (the SVG is drawn for its size).
  var ro = window.ResizeObserver ? new ResizeObserver(function (entries) {
    entries.forEach(function (en) {
      var h = en.target, c = h.__kitChart;
      if (!c || h.__kitWidth === Math.round(en.contentRect.width)) return;
      h.__kitWidth = Math.round(en.contentRect.width);
      kinds[c.kind](h, c.data);
    });
  }) : null;
  var api = {};
  Object.keys(kinds).forEach(function (k) { api[k] = function (host, data) { render(host, k, data); if (ro) ro.observe(host); }; });
  window.KitCharts = api;

  function startCharts() {
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-chart]"), function (host) {
      var data;
      try { data = JSON.parse(host.getAttribute("data-kit-data") || "{}"); } catch (e) { return; }
      api[host.getAttribute("data-kit-chart")] && api[host.getAttribute("data-kit-chart")](host, data);
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startCharts); else startCharts();
})();
