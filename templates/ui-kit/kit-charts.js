/*
  UI kit charts for plain pages (no build step, no library, works from file://): bar (grouped or
  stacked), line, area, ring, gauge, heatmap, sparkline and barlist, drawn on the kit's tokens
  (--kit-chart-1..6, in that order: series 1 is always --kit-chart-1).
  Design adapted from bklit-ui chart components (MIT licence, see LICENSE-bklit-ui.txt):
  dashed grid, bars rounded at their outer end, fading area fill, hover highlight with tooltip,
  legend, grow-in.

  Declarative: <div class="kit-chart" data-kit-chart="bar" data-kit-data='{"labels":[...],
  "series":[{"name":"A","values":[...]}]}' aria-label="What the chart shows"></div>
  From code: KitCharts.bar(element, data). Every chart also writes a hidden data table for
  screen readers, and redraws when its box changes size.

  Filtering (bar, line, area, ring, barlist): data.selectable makes bars, ring parts, list rows and
  legend items buttons; a click or Enter sends the event kit:select (it bubbles) with detail
  { chart, part: "bar" | "arc" | "row" | "legend", value, index, series, seriesIndex }: value is
  the label picked (a series name for a bar or line legend). Draw the chart again with
  data.selected (labels) and data.selectedSeries (series names) to show what is picked; the rest
  fades.

  Colours by meaning (barlist and ring items, barlist data.color): "ok", "warn", "error", "muted",
  "accent" or "chart-1" ... "chart-6", always kit tokens; a label still says what each one means.
  Bar list extras: data.share (value and share), data.base "first" (a funnel). Bar chart: a series
  with type "line" (and axis "right" for its own scale) is drawn as a line over the bars.
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
  // A colour by meaning or by name: ok, warn, error, muted, accent, chart-1 ... chart-6, or a kit
  // token as var(--kit-...). Anything else (a hard-coded colour) is not used: the fallback is.
  var TONES = { ok: "--kit-ok", warn: "--kit-warn", error: "--kit-error", muted: "--kit-text-muted", accent: "--kit-accent" };
  function tone(name, fallback) {
    var n = String(name === undefined || name === null ? "" : name).trim(), m;
    if (TONES[n]) return "var(" + TONES[n] + ")";
    if ((m = /^chart-([1-6])$/.exec(n))) return "var(--kit-chart-" + m[1] + ")";
    if (/^var\(--kit-[\w-]+\)$/.test(n)) return n;
    return fallback;
  }
  function percent(v, total) { return total ? Math.round((v / total) * 1000) / 10 + "%" : "-"; }
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
    // In a 1px box that clips it: a table grows to its content, which would widen the page.
    var box = document.createElement("div");
    box.className = "kit-chart__table";
    var t = document.createElement("table");
    var tr = t.insertRow();
    head.forEach(function (h) { var th = document.createElement("th"); th.textContent = h; tr.appendChild(th); });
    rows.forEach(function (r) { var row = t.insertRow(); r.forEach(function (c) { row.insertCell().textContent = c; }); });
    box.appendChild(t);
    host.appendChild(box);
  }
  // What is picked (data.selected: labels, data.selectedSeries: series names); nothing = all on.
  function picked(list) { return list && list.length ? list.map(String) : null; }
  function isOff(list, name) { var p = picked(list); return !!p && p.indexOf(String(name)) < 0; }
  // A clickable part (data.selectable): a button for mouse and keyboard that sends kit:select.
  function pickable(host, data, el, detail, name) {
    if (!data.selectable) return;
    var p = picked(detail.part === "legend" && detail.series !== undefined ? data.selectedSeries : data.selected);
    el.setAttribute("tabindex", "0");
    if (el.tagName.toLowerCase() !== "button") el.setAttribute("role", "button");
    el.setAttribute("aria-pressed", p && p.indexOf(String(detail.value)) >= 0 ? "true" : "false");
    if (name) el.setAttribute("aria-label", name);
    var fire = function () { host.dispatchEvent(new CustomEvent("kit:select", { bubbles: true, detail: detail })); };
    el.addEventListener("click", fire);
    el.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); fire(); } });
  }
  // Legend under a chart. opts.pick(i) gives the kit:select detail of entry i, opts.off(i) fades it,
  // opts.colors[i] its colour (default: the series colours in order).
  function legend(host, names, onHover, data, opts) {
    if (names.length < 2) return;
    var ul = document.createElement("ul");
    ul.className = "kit-chart__legend";
    names.forEach(function (n, i) {
      var li = document.createElement("li");
      li.innerHTML = '<span class="kit-chart__swatch" style="background:' + (opts && opts.colors ? opts.colors[i] : color(i)) + '"></span>';
      li.appendChild(document.createTextNode(n));
      li.addEventListener("mouseenter", function () { onHover(i); });
      li.addEventListener("mouseleave", function () { onHover(-1); });
      if (opts && opts.off && opts.off(i)) li.classList.add("is-off");
      if (opts && opts.pick) pickable(host, data, li, opts.pick(i));
      ul.appendChild(li);
    });
    host.appendChild(ul);
  }
  // A bar rounded only at its outer end (the end away from the axis), so it stands on the axis.
  function barPath(a, r, horizontal) {
    var x = a.x, y = a.y, w = a.width, h = a.height;
    r = Math.max(0, Math.min(r, horizontal ? h / 2 : w / 2, horizontal ? w : h));
    if (!r) return "M" + x + " " + y + "h" + w + "v" + h + "h" + (-w) + "Z";
    if (horizontal) return "M" + x + " " + y + "H" + (x + w - r) + "A" + r + " " + r + " 0 0 1 " + (x + w) + " " + (y + r) + "V" + (y + h - r) + "A" + r + " " + r + " 0 0 1 " + (x + w - r) + " " + (y + h) + "H" + x + "Z";
    return "M" + x + " " + (y + h) + "V" + (y + r) + "A" + r + " " + r + " 0 0 1 " + (x + r) + " " + y + "H" + (x + w - r) + "A" + r + " " + r + " 0 0 1 " + (x + w) + " " + (y + r) + "V" + (y + h) + "Z";
  }
  function empty(host, data) {
    var d = document.createElement("div");
    d.className = "kit-empty";
    d.textContent = data.empty || "Nothing to show";
    host.appendChild(d);
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
  // Target or reference lines (data.targets: [{ value, label }]): dashed across the plot at the value,
  // with its label at the end; horizontal bars get them upright.
  function targetMax(data) { return Math.max.apply(null, [0].concat((data.targets || []).map(function (t) { return Number(t && t.value) || 0; }))); }
  function targets(svg, s, pad, scale, data, horizontal) {
    (data.targets || []).forEach(function (t) {
      var v = Number(t && t.value);
      if (!t || isNaN(v) || v < 0 || v > scale.max) return;
      var g = svgEl("g", { class: "kit-chart__targets" }, svg), txt;
      if (horizontal) {
        var x = pad.l + (s.w - pad.l - pad.r) * (v / scale.max);
        svgEl("line", { x1: x, x2: x, y1: pad.t, y2: s.h - pad.b, class: "kit-chart__target" }, g);
        txt = svgEl("text", { x: x, y: pad.t - 2 > 8 ? pad.t - 2 : s.h - pad.b + 14, "text-anchor": "middle", class: "kit-chart__target-label" }, g);
      } else {
        var y = pad.t + (s.h - pad.t - pad.b) * (1 - v / scale.max);
        svgEl("line", { x1: pad.l, x2: s.w - pad.r, y1: y, y2: y, class: "kit-chart__target" }, g);
        txt = svgEl("text", { x: s.w - pad.r - 4, y: y - 5, "text-anchor": "end", class: "kit-chart__target-label" }, g);
      }
      txt.textContent = (t.label ? t.label + ": " : "") + fmt(v, data);
    });
  }
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
  function series(data) {
    return (data.series || []).map(function (sr, i) {
      return { name: sr.name || "", values: (sr.values || []).map(Number), i: i, line: sr.type === "line", right: sr.type === "line" && sr.axis === "right" };
    });
  }

  // Bar chart: grouped bars per label, or data.stacked for one bar per label with the series on
  // top of each other; data.horizontal for bars to the right. A series with type "line" is drawn
  // as a line over the bars (not with horizontal), on its own scale at the right with axis "right"
  // (a running total next to the counts per day).
  function bar(host, data) {
    clear(host);
    var all = series(data), labels = data.labels || [], s = size(host), horizontal = !!data.horizontal;
    var sr = all.filter(function (x) { return horizontal || !x.line; }), ln = horizontal ? [] : all.filter(function (x) { return x.line; });
    if (!labels.length || !all.length) { empty(host, data); return; }
    var stacked = !!data.stacked && sr.length > 1;
    var pct = stacked && data.stacked === "percent";   // every bar 100%: the parts as shares
    var total = function (li) { return sr.reduce(function (a, x) { return a + Math.max(0, x.values[li] || 0); }, 0); };
    var maxOf = function (list) { return Math.max.apply(null, [0].concat.apply([], list.map(function (x) { return x.values; }))); };
    var left = ln.filter(function (x) { return !x.right; }), right = ln.filter(function (x) { return x.right; });
    var max = Math.max(stacked ? Math.max.apply(null, [0].concat(labels.map(function (l, li) { return total(li); }))) : maxOf(sr), maxOf(left));
    var scale = pct ? { max: 100, step: 25 } : niceMax(Math.max(max, targetMax(data)), 4), rscale = right.length ? niceMax(maxOf(right), 4) : null;
    var axis = pct ? Object.assign({}, data, { format: function (v) { return Math.round(v * 10) / 10 + "%"; } }) : data;
    var tip = null, bars = [], marks = [];
    var svg = frame(host, s, data.title);
    var pad = horizontal ? { t: 8, r: 16, b: 24, l: 96 } : { t: 12, r: rscale ? 52 : 12, b: 28, l: 44 };
    var plotW = s.w - pad.l - pad.r, plotH = s.h - pad.t - pad.b;
    if (!horizontal) grid(svg, s, pad, scale, axis);
    if (rscale) for (var rv = 0; rv <= rscale.max + 1e-9; rv += rscale.step) {
      var ry = pad.t + (s.h - pad.t - pad.b) * (1 - rv / rscale.max);
      var rt = svgEl("text", { x: s.w - pad.r + 8, y: ry + 4, class: "kit-chart__label" }, svg);
      rt.textContent = fmt(rv, data);
      if (right.length === 1) rt.style.fill = color(right[0].i);
    }
    var band = (horizontal ? plotH : plotW) / Math.max(1, labels.length);
    var lstep = horizontal ? 1 : labelStep(labels, plotW);
    var inner = band * 0.72, bw = stacked ? Math.max(1, inner) : Math.max(2, inner / Math.max(1, sr.length) - 2);
    var room = horizontal ? plotW : plotH;
    labels.forEach(function (lab, li) {
      var start = (horizontal ? pad.t : pad.l) + li * band + (band - inner) / 2;
      var acc = 0, top = -1;
      if (stacked) sr.forEach(function (x, si) { if ((x.values[li] || 0) > 0) top = si; });
      sr.forEach(function (x, si) {
        var v = x.values[li] || 0, tot = total(li);
        if (pct) v = tot ? (Math.max(0, v) / tot) * 100 : 0;
        var len = room * (Math.max(0, v) / scale.max), from = room * (acc / scale.max);
        if (stacked && v <= 0) return;
        var a;
        if (stacked) {
          if (horizontal) a = { x: pad.l + from, y: start, width: len, height: bw };
          else a = { x: start, y: pad.t + plotH - from - len, width: bw, height: len };
          acc += Math.max(0, v);
        } else if (horizontal) a = { x: pad.l, y: start + si * (bw + 2), width: Math.max(0, len), height: bw };
        else a = { x: start + si * (bw + 2), y: pad.t + plotH - len, width: bw, height: Math.max(0, len) };
        var r = stacked && si !== top ? 0 : Math.min(bw / 4, 4);
        var rect = svgEl("path", { d: barPath(a, r, horizontal), fill: color(x.i), class: "kit-chart__bar" }, svg);
        if (isOff(data.selected, lab) || isOff(data.selectedSeries, x.name)) rect.classList.add("is-off");
        if (!reduce) rect.style.animation = (horizontal ? "kit-grow-x" : "kit-grow-y") + " 520ms cubic-bezier(0.22, 1, 0.36, 1) both";
        if (!reduce) rect.style.transformOrigin = horizontal ? (pad.l + "px 0") : ("0 " + (pad.t + plotH) + "px");
        var text = stacked
          ? "<strong>" + esc(lab) + "</strong> &middot; " + esc(fmt(total(li), data)) + sr.map(function (y) { return (y.values[li] || 0) > 0 ? "<br>" + esc(y.name || "Value") + ": " + esc(fmt(y.values[li], data)) + (pct ? " (" + percent(y.values[li], total(li)) + ")" : "") : ""; }).join("")
          : "<strong>" + esc(lab) + "</strong><br>" + (x.name ? esc(x.name) + ": " : "") + esc(fmt(v, data));
        text += ln.map(function (y) { return "<br>" + esc(y.name || "Value") + ": " + esc(fmt(y.values[li] || 0, data)); }).join("");
        var show = function () {
          bars.forEach(function (b) { b.el.classList.toggle("is-faded", stacked ? b.li !== li : b.el !== rect); });
          var box = rect.getBBox();
          tip.show(text, box.x + box.width / 2, horizontal ? box.y : Math.min(box.y, pad.t + plotH - room * (total(li) / scale.max)));
        };
        rect.addEventListener("mouseenter", show);
        rect.addEventListener("focus", show);
        var hide = function () { bars.forEach(function (b) { b.el.classList.remove("is-faded"); }); tip.hide(); };
        rect.addEventListener("mouseleave", hide);
        rect.addEventListener("blur", hide);
        pickable(host, data, rect, { chart: "bar", part: "bar", value: lab, index: li, series: x.name, seriesIndex: x.i }, lab + (x.name ? ", " + x.name : "") + ": " + fmt(v, data));
        bars.push({ el: rect, s: x.i, li: li });
      });
      if (li % lstep) return;
      var t = horizontal
        ? svgEl("text", { x: pad.l - 8, y: start + inner / 2 + 4, "text-anchor": "end", class: "kit-chart__label" }, svg)
        : svgEl("text", { x: start + inner / 2, y: s.h - 8, "text-anchor": "middle", class: "kit-chart__label" }, svg);
      t.textContent = lab;
    });
    if (!pct) targets(svg, s, pad, scale, data, horizontal);
    // Line series over the bars: through the middle of each label's band.
    ln.forEach(function (x) {
      var sc = x.right ? rscale : scale;
      var px = function (i) { return pad.l + band * (i + 0.5); }, py = function (v) { return pad.t + plotH * (1 - Math.max(0, v) / sc.max); };
      var d = labels.map(function (l, i) { return (i ? "L" : "M") + px(i).toFixed(1) + " " + py(x.values[i] || 0).toFixed(1); }).join(" ");
      var p = svgEl("path", { d: d, fill: "none", stroke: color(x.i), "stroke-width": 2.25, "stroke-linejoin": "round", "stroke-linecap": "round", class: "kit-chart__path" }, svg);
      if (isOff(data.selectedSeries, x.name)) p.classList.add("is-off");
      if (!reduce && p.getTotalLength) { var L = p.getTotalLength(); p.style.strokeDasharray = L; p.style.strokeDashoffset = L; p.style.animation = "kit-draw 700ms cubic-bezier(0.22, 1, 0.36, 1) forwards"; }
      marks.push({ el: p, s: x.i });
      if (labels.length <= 60) labels.forEach(function (l, i) { marks.push({ el: svgEl("circle", { cx: px(i), cy: py(x.values[i] || 0), r: 3, fill: color(x.i), class: "kit-chart__dot" }, svg), s: x.i }); });
    });
    tip = tooltip(host);
    legend(host, all.map(function (x) { return x.name + (x.right && rscale ? " (right axis)" : ""); }), function (i) {
      bars.forEach(function (b) { b.el.classList.toggle("is-faded", i >= 0 && b.s !== i); });
      marks.forEach(function (m) { m.el.classList.toggle("is-faded", i >= 0 && m.s !== i); });
    }, data, {
      off: function (i) { return isOff(data.selectedSeries, all[i].name); },
      pick: function (i) { return { chart: "bar", part: "legend", value: all[i].name, index: i, series: all[i].name, seriesIndex: i }; }
    });
    dataTable(host, [""].concat(all.map(function (x) { return x.name || "Value"; })), labels.map(function (l, li) { return [l].concat(all.map(function (x) { return fmt(x.values[li] || 0, data); })); }));
  }

  // Line chart (data.area for a fading fill under each line).
  function line(host, data, area) {
    clear(host);
    var sr = series(data), labels = data.labels || [], s = size(host);
    var all = [].concat.apply([], sr.map(function (x) { return x.values; }));
    var scale = niceMax(Math.max(Math.max.apply(null, [0].concat(all)), targetMax(data)), 4);
    var svg = frame(host, s, data.title);
    var pad = { t: 12, r: 16, b: 28, l: 44 }, plotW = s.w - pad.l - pad.r, plotH = s.h - pad.t - pad.b;
    grid(svg, s, pad, scale, data);
    targets(svg, s, pad, scale, data, false);
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
    paths.forEach(function (p, pi) { if (isOff(data.selectedSeries, sr[pi].name)) p.classList.add("is-off"); });
    legend(host, sr.map(function (x) { return x.name; }), function (i) { paths.forEach(function (p, pi) { p.classList.toggle("is-faded", i >= 0 && pi !== i); }); }, data, {
      off: function (i) { return isOff(data.selectedSeries, sr[i].name); },
      pick: function (i) { return { chart: "line", part: "legend", value: sr[i].name, index: i, series: sr[i].name, seriesIndex: i }; }
    });
    dataTable(host, [""].concat(sr.map(function (x) { return x.name || "Value"; })), labels.map(function (l, li) { return [l].concat(sr.map(function (x) { return fmt(x.values[li] || 0, data); })); }));
  }

  // Ring (donut): data.items [{ label, value }]; data.center for the text in the middle;
  // data.legend "values" for a legend with each value and its share (a list under the ring).
  // Colours follow the items' order, also past an item at 0, so an item keeps its colour; an
  // item's color (ok, warn, error, muted, accent, chart-N) gives it a colour by meaning instead.
  function ring(host, data) {
    clear(host);
    var items = (data.items || []).map(function (it, i) { return { label: String(it.label), value: Math.max(0, Number(it.value) || 0), color: tone(it.color, color(i)) }; });
    var sum = items.reduce(function (a, b) { return a + b.value; }, 0), total = sum || 1;
    var share = function (v) { return sum ? percent(v, total) : "-"; };
    var s = size(host, Number(host.getAttribute("data-kit-height")) || 220), cx = s.h / 2, cy = s.h / 2, R = s.h / 2 - 8, w = Math.max(10, R * 0.22);
    host.classList.add("kit-chart--ring");
    var svg = frame(host, { w: s.h, h: s.h }, data.title), tip = tooltip(host), arcs = [];
    var shown = items.filter(function (it) { return it.value > 0; }).length;
    var a0 = -Math.PI / 2, gap = shown > 1 ? 0.025 : 0, r = R - w / 2;
    svgEl("circle", { cx: cx, cy: cy, r: r, fill: "none", stroke: "var(--kit-surface-2)", "stroke-width": w }, svg);
    items.forEach(function (it, i) {
      if (!it.value) { arcs.push(null); return; }
      var a1 = a0 + (it.value / total) * Math.PI * 2;
      var s0 = a0 + gap / 2, s1 = Math.max(s0 + 0.001, a1 - gap / 2);
      var p;
      if (shown === 1) p = svgEl("circle", { cx: cx, cy: cy, r: r, fill: "none", stroke: it.color, "stroke-width": w, class: "kit-chart__arc" }, svg);
      else {
        var large = s1 - s0 > Math.PI ? 1 : 0;
        var d = "M" + (cx + r * Math.cos(s0)) + " " + (cy + r * Math.sin(s0)) + " A" + r + " " + r + " 0 " + large + " 1 " + (cx + r * Math.cos(s1)) + " " + (cy + r * Math.sin(s1));
        p = svgEl("path", { d: d, fill: "none", stroke: it.color, "stroke-width": w, "stroke-linecap": "butt", class: "kit-chart__arc" }, svg);
      }
      if (isOff(data.selected, it.label)) p.classList.add("is-off");
      var show = function () {
        arcs.forEach(function (x) { if (x) x.classList.toggle("is-faded", x !== p); });
        tip.show("<strong>" + esc(it.label) + "</strong><br>" + esc(fmt(it.value, data)) + " (" + share(it.value) + ")", cx, cy - R / 3);
      };
      var hide = function () { arcs.forEach(function (x) { if (x) x.classList.remove("is-faded"); }); tip.hide(); };
      p.addEventListener("mouseenter", show); p.addEventListener("focus", show);
      p.addEventListener("mouseleave", hide); p.addEventListener("blur", hide);
      pickable(host, data, p, { chart: "ring", part: "arc", value: it.label, index: i }, it.label + ": " + fmt(it.value, data) + " (" + share(it.value) + ")");
      arcs.push(p);
      a0 = a1;
    });
    if (data.center !== undefined) svgEl("text", { x: cx, y: cy + 6, "text-anchor": "middle", class: "kit-chart__center" }, svg).textContent = data.center;
    var hover = function (i) { arcs.forEach(function (x, xi) { if (x) x.classList.toggle("is-faded", i >= 0 && xi !== i); }); };
    var pick = function (i) { return { chart: "ring", part: "legend", value: items[i].label, index: i }; };
    if (data.legend === "values") {
      var ul = document.createElement("ul");
      ul.className = "kit-chart__legend kit-chart__legend--values";
      items.forEach(function (it, i) {
        var li = document.createElement("li");
        if (!it.value) li.classList.add("is-zero");
        if (isOff(data.selected, it.label)) li.classList.add("is-off");
        li.innerHTML = '<span class="kit-chart__swatch" style="background:' + it.color + '"></span><span class="kit-chart__legend-label">' + esc(it.label) +
          '</span><span class="kit-chart__legend-value">' + esc(fmt(it.value, data)) + '</span><span class="kit-chart__legend-share">' + share(it.value) + "</span>";
        li.addEventListener("mouseenter", function () { hover(i); });
        li.addEventListener("mouseleave", function () { hover(-1); });
        pickable(host, data, li, pick(i));
        ul.appendChild(li);
      });
      host.appendChild(ul);
    } else legend(host, items.map(function (it) { return it.label; }), hover, data, { off: function (i) { return isOff(data.selected, items[i].label); }, pick: pick, colors: items.map(function (it) { return it.color; }) });
    dataTable(host, ["", "Value", "Share"], items.map(function (it) { return [it.label, fmt(it.value, data), share(it.value)]; }));
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

  // Bar list: one row per item (label, bar, value) in the order given, for categories (countries,
  // departments, statuses: top ten, per person, per place) and for the steps of a process.
  // data.items [{ label, value, color }]; data.limit shows that many rows with a Show all button
  // (picked rows always show); data.color the colour of every bar and item.color one row's, by
  // meaning (ok, warn, error, muted, accent) or series (chart-1 ... chart-6; default chart-1);
  // data.share adds each value's share ("1,234 - 56.7%", with a middle dot) of data.total (default: the sum, or the
  // first item with data.base "first"); data.base "first" is a funnel: every bar against the
  // first item (the whole), so each step shows how many are left; data.selectable makes each row
  // a button.
  function barlist(host, data) {
    clear(host);
    var all = tone(data.color, color(0));
    var items = (data.items || []).map(function (it) { return { label: String(it.label), value: Number(it.value) || 0, color: tone(it.color, all) }; });
    if (!items.length) { empty(host, data); return; }
    var limit = Number(data.limit) || 0, open = !!host.__kitOpen, sel = picked(data.selected);
    var shown = items.map(function (it, i) { return { it: it, i: i }; });
    if (limit && !open && items.length > limit) shown = shown.filter(function (x) { return x.i < limit || (sel && sel.indexOf(x.it.label) >= 0); });
    var first = data.base === "first" ? Math.max(0, items[0].value) : 0;
    var max = first || Math.max.apply(null, [0].concat(shown.map(function (x) { return x.it.value; }))) || 1;
    var whole = Number(data.total) || first || items.reduce(function (a, it) { return a + Math.max(0, it.value); }, 0);
    var text = function (v) { return fmt(v, data) + (data.share ? " \u00b7 " + percent(v, whole) : ""); };
    var list = document.createElement("div");
    list.className = data.share ? "kit-barlist kit-barlist--share" : "kit-barlist";
    if (!data.selectable) list.setAttribute("role", "list");
    list.setAttribute("aria-label", data.title || host.getAttribute("aria-label") || "Bar list");
    shown.forEach(function (x) {
      var it = x.it, row = document.createElement(data.selectable ? "button" : "div");
      if (data.selectable) row.type = "button"; else row.setAttribute("role", "listitem");
      row.className = "kit-barlist__row" + (sel ? (sel.indexOf(it.label) >= 0 ? " is-on" : " is-off") : "");
      row.title = it.label + ": " + text(it.value);
      row.innerHTML = '<span class="kit-barlist__label">' + esc(it.label) + '</span><span class="kit-barlist__track"><span class="kit-barlist__fill" style="width:' +
        Math.min(100, 100 * Math.max(0, it.value) / max).toFixed(1) + "%;background:" + it.color + '"></span></span><span class="kit-barlist__value">' +
        (data.share ? "<b>" + esc(fmt(it.value, data)) + "</b> \u00b7 " + percent(it.value, whole) : esc(fmt(it.value, data))) + "</span>";
      if (!reduce) row.querySelector(".kit-barlist__fill").style.animation = "kit-grow-x 520ms cubic-bezier(0.22, 1, 0.36, 1) both";
      pickable(host, data, row, { chart: "barlist", part: "row", value: it.label, index: x.i }, it.label + ": " + text(it.value));
      list.appendChild(row);
    });
    host.appendChild(list);
    if (limit && items.length > limit) {
      var more = document.createElement("button");
      more.type = "button";
      more.className = "kit-btn kit-btn--ghost kit-btn--sm kit-barlist__more";
      more.setAttribute("aria-expanded", open ? "true" : "false");
      more.textContent = open ? "Show the top " + limit : "Show all " + items.length;
      more.addEventListener("click", function () { host.__kitOpen = !open; barlist(host, data); var b = host.querySelector(".kit-barlist__more"); if (b) b.focus(); });
      host.appendChild(more);
    }
  }

  var kinds = { bar: bar, line: function (h, d) { line(h, d, false); }, area: function (h, d) { line(h, d, true); }, ring: ring, gauge: gauge, heatmap: heatmap, sparkline: sparkline, barlist: barlist };
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
  // The project's chart colours (--kit-chart-1 ... --kit-chart-6, the colour preset's) as colour
  // values for code that cannot use var(): a canvas, a chart drawn by the page itself. n colours
  // in order, repeating after six; read again after a theme switch (kit:theme), they differ in dark.
  api.palette = function (n) {
    var st = getComputedStyle(document.documentElement), out = [];
    for (var i = 0; i < (n || 6); i++) out.push(st.getPropertyValue("--kit-chart-" + ((i % 6) + 1)).trim());
    return out;
  };
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
