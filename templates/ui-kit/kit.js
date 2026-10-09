/*
  UI kit behaviour for plain pages (no build step, works from file://). Load after the page's
  markup: <script src="styles/kit/kit.js"></script>. Each part starts on its data-kit-* attribute
  and reports through a DOM event, so page code listens instead of editing this file.
  Behaviour adapted from kokonutui (MIT licence, see LICENSE-kokonutui.txt; https://kokonutui.com):
  hold-button, action-search-bar, file-upload, smooth-tab.
  The sortable table with pages (data-kit-sort, data-kit-pages, data-kit-rows="external") and the
  theme switch (data-kit-theme) are the kit's own.
*/
(function () {
  "use strict";
  if (window.KitUI) return;   // loaded twice (head and tail of the page): once is enough

  // Hold to confirm: <button class="kit-btn kit-btn--hold" data-kit-hold="1500">Delete</button>
  // Fires "kit:hold" on the button when held long enough (mouse, touch, Space or Enter).
  function setupHold(btn) {
    if (btn.kitHold) return;
    btn.kitHold = true;
    var ms = parseInt(btn.getAttribute("data-kit-hold"), 10) || 1500;
    var timer = null;
    btn.style.setProperty("--kit-hold-ms", ms + "ms");
    function begin(e) {
      if (timer || btn.disabled) return;
      if (e && e.type === "keydown" && e.key !== " " && e.key !== "Enter") return;
      if (e && e.type === "keydown") e.preventDefault();
      btn.classList.remove("is-done");
      btn.classList.add("is-holding");
      timer = setTimeout(function () {
        timer = null;
        btn.classList.remove("is-holding");
        btn.classList.add("is-done");
        btn.dispatchEvent(new CustomEvent("kit:hold", { bubbles: true }));
      }, ms);
    }
    function stop() {
      if (!timer) return;
      clearTimeout(timer);
      timer = null;
      btn.classList.remove("is-holding");
    }
    btn.addEventListener("pointerdown", begin);
    btn.addEventListener("keydown", begin);
    ["pointerup", "pointerleave", "pointercancel", "keyup", "blur"].forEach(function (n) { btn.addEventListener(n, stop); });
  }

  // Search with suggestions: <div class="kit-search" data-kit-search><input class="kit-input">
  // <ul class="kit-search__list"><li class="kit-search__item">...</li></ul></div>
  // Filters the items as you type; arrow keys and Enter pick one. Fires "kit:pick" with { text }.
  function setupSearch(box) {
    if (box.kitSearch) return;
    var input = box.querySelector("input");
    var list = box.querySelector(".kit-search__list");
    if (!input || !list) return;
    box.kitSearch = true;
    var items = Array.prototype.slice.call(list.querySelectorAll(".kit-search__item"));
    var active = -1;
    if (!list.id) list.id = "kit-search-" + Math.random().toString(36).slice(2, 8);
    list.setAttribute("role", "listbox");
    items.forEach(function (i, n) { i.setAttribute("role", "option"); if (!i.id) i.id = list.id + "-" + n; });
    input.setAttribute("role", "combobox"); input.setAttribute("aria-autocomplete", "list"); input.setAttribute("aria-controls", list.id); input.setAttribute("aria-expanded", "false");
    function visible() { return items.filter(function (i) { return !i.hidden; }); }
    function mark(n) {
      var v = visible();
      items.forEach(function (i) { i.classList.remove("is-active"); i.removeAttribute("aria-selected"); });
      active = v.length ? (n + v.length) % v.length : -1;
      if (active >= 0) { v[active].classList.add("is-active"); v[active].setAttribute("aria-selected", "true"); input.setAttribute("aria-activedescendant", v[active].id); }
      else input.removeAttribute("aria-activedescendant");
    }
    function open(on) { list.hidden = !on; input.setAttribute("aria-expanded", String(on)); }
    function pick(item) {
      if (!item) return;
      input.value = item.getAttribute("data-value") || item.textContent.trim();
      open(false);
      box.dispatchEvent(new CustomEvent("kit:pick", { bubbles: true, detail: { text: input.value } }));
    }
    function filter() {
      var q = input.value.trim().toLowerCase();
      items.forEach(function (i) { i.hidden = q !== "" && i.textContent.toLowerCase().indexOf(q) < 0; });
      open(visible().length > 0);
      mark(-1);
    }
    input.addEventListener("input", filter);
    input.addEventListener("focus", filter);
    input.addEventListener("blur", function () { setTimeout(function () { open(false); }, 120); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown") { e.preventDefault(); mark(active + 1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); mark(active - 1); }
      else if (e.key === "Enter" && active >= 0) { e.preventDefault(); pick(visible()[active]); }
      else if (e.key === "Escape") { open(false); }
    });
    items.forEach(function (i) { i.addEventListener("mousedown", function (e) { e.preventDefault(); pick(i); }); });
    open(false);
  }

  // File drop zone: <label class="kit-drop" data-kit-drop><input type="file" multiple> ...</label>
  // Highlights while a file is over it and lists the chosen files. Fires "kit:files" with { files }.
  function setupDrop(zone) {
    if (zone.kitDrop) return;
    zone.kitDrop = true;
    var input = zone.querySelector('input[type="file"]');
    var out = zone.querySelector(".kit-drop__files");
    function show(files) {
      if (out) out.innerHTML = Array.prototype.map.call(files, function (f) { return "<li>" + f.name.replace(/[<>&]/g, "") + "</li>"; }).join("");
      zone.dispatchEvent(new CustomEvent("kit:files", { bubbles: true, detail: { files: files } }));
    }
    ["dragenter", "dragover"].forEach(function (n) { zone.addEventListener(n, function (e) { e.preventDefault(); zone.classList.add("is-over"); }); });
    ["dragleave", "drop"].forEach(function (n) { zone.addEventListener(n, function () { zone.classList.remove("is-over"); }); });
    zone.addEventListener("drop", function (e) { e.preventDefault(); if (e.dataTransfer && e.dataTransfer.files.length) show(e.dataTransfer.files); });
    if (input) input.addEventListener("change", function () { if (input.files.length) show(input.files); });
  }

  // Animated tabs / segmented choice: add kit-tabs--animated or kit-segmented--animated.
  // Clicking a tab selects it (aria-selected / aria-pressed) and slides the indicator; fires "kit:select".
  function setupSlider(group, itemSel, attr, indicatorClass) {
    if (group.kitSlider) return;
    group.kitSlider = true;
    var ind = document.createElement("span");
    ind.className = indicatorClass;
    ind.setAttribute("aria-hidden", "true");
    group.appendChild(ind);
    var buttons = Array.prototype.slice.call(group.querySelectorAll(itemSel));
    function move() {
      var cur = buttons.filter(function (b) { return b.getAttribute(attr) === "true"; })[0];
      if (!cur) { ind.style.width = "0"; return; }
      ind.style.width = cur.offsetWidth + "px";
      ind.style.transform = "translateX(" + cur.offsetLeft + "px)";
    }
    buttons.forEach(function (b) {
      b.addEventListener("click", function () {
        buttons.forEach(function (o) { o.setAttribute(attr, o === b ? "true" : "false"); });
        move();
        group.dispatchEvent(new CustomEvent("kit:select", { bubbles: true, detail: { value: b.getAttribute("data-value") || b.textContent.trim(), text: b.textContent.trim(), index: buttons.indexOf(b) } }));
      });
    });
    window.addEventListener("resize", move);
    move();
  }

  // Sortable table with pages (the kit's own part, not from kokonutui):
  // <table class="kit-table" data-kit-sort data-kit-pages="25">. data-kit-sort makes every header
  // a sort button (a th with data-kit-nosort stays plain; th.kit-num sorts as numbers; a cell's
  // data-sort="VALUE" sorts by that value, for dates or formatted numbers); data-kit-pages="N"
  // shows N rows at a time with a kit-pager under the table. An empty-state row
  // (<tr data-kit-empty>) is never sorted or paged. When the page writes the rows again, they are
  // sorted again and paging starts at the first page. Fires "kit:sort" { column, key, ascending }
  // (key: the header's data-key) and "kit:page" { page, pages, start, end } on the table.
  // Many rows (thousands): data-kit-rows="external" leaves the rows to the page. The kit only
  // draws the sort buttons and the pager and sends the events; the page keeps all rows in its
  // data, sorts them on kit:sort, writes only the rows from start to end (kit:page; start counts
  // from 0, end not included) and sets data-kit-total="ROWS" (and data-kit-page="N" to go to a
  // page, e.g. 1 after a filter change) on the table, which the pager follows.
  function setupTable(table) {
    // Once per table; a table a script writes after the page loaded is set up when it appears, and a
    // header row or body it writes later is picked up too (startKit's observer, the one below).
    if (table.kitTable) return;
    table.kitTable = true;
    var body = table.tBodies[0];
    var external = table.getAttribute("data-kit-rows") === "external";
    var size = parseInt(table.getAttribute("data-kit-pages"), 10) || 0;
    var heads = [];
    var col = -1, asc = true, page = 0, pager = null, info = null, prev = null, next = null, obs = null, query = "", matched = 0;
    var sortedCol = -1, sortedAsc = true, numSep = {};
    function rows() { return body ? Array.prototype.filter.call(body.rows, function (r) { return !r.hasAttribute("data-kit-empty"); }) : []; }
    function value(row, i) {
      var c = row.cells[i];
      if (!c) return "";
      var v = c.getAttribute("data-sort");
      return v === null ? c.textContent.trim() : v;
    }
    // Numbers as people write them (kit-num columns): "1,234.56", "1.234,56", "41,7%", "(1,234)",
    // "5.210". The column decides its decimal separator: a value with 1, 2 or 4+ digits after a
    // separator makes that one the decimal; dots only in groups of three are thousands.
    function decimalSep(i) {
      if (numSep[i]) return numSep[i];
      var comma = false, dot = false, dotGroups = true;
      rows().forEach(function (r) {
        var v = value(r, i).replace(/[^\d.,]/g, "");
        if (/,\d{3}\./.test(v) || /\.\d{1,2}$/.test(v) || /\.\d{4,}$/.test(v)) dot = true;
        if (/\.\d{3},/.test(v) || /,\d{1,2}$/.test(v) || /,\d{4,}$/.test(v)) comma = true;
        if (v.indexOf(".") >= 0 && !/^\d{1,3}(\.\d{3})+$/.test(v.replace(/,.*$/, ""))) dotGroups = false;
      });
      numSep[i + "g"] = dotGroups && !dot;   // every dot in the column groups thousands ("5.210")
      return (numSep[i] = comma && !dot ? "," : ".");
    }
    function toNumber(s, i) {
      var raw = String(s).trim();
      if (!raw) return NaN;
      var neg = /^\(.*\)$/.test(raw) || /^[^\d]*-/.test(raw);
      var v = raw.replace(/[^\d.,]/g, "");
      if (!v) return NaN;
      var sep = decimalSep(i);
      if (sep === ",") v = v.replace(/\./g, "").replace(",", ".");
      else { v = v.replace(/,/g, ""); if (numSep[i + "g"] && /^\d{1,3}(\.\d{3})+$/.test(v)) v = v.replace(/\./g, ""); }
      var n = parseFloat(v);
      return isNaN(n) ? NaN : (neg ? -n : n);
    }
    function sortKey(row) {
      var k = row.__kitKeys || (row.__kitKeys = {});
      if (k[col] === undefined) k[col] = heads[col] && heads[col].classList.contains("kit-num") ? toNumber(value(row, col), col) : value(row, col);
      return k[col];
    }
    function compare(a, b) {
      var x = sortKey(a), y = sortKey(b), c;
      if (typeof x === "number" || typeof y === "number") {
        var nx = typeof x === "number" && !isNaN(x), ny = typeof y === "number" && !isNaN(y);
        if (!nx && !ny) return 0;
        if (!nx) return 1;   // what is not a number (empty, "n/a") sorts last, whichever way
        if (!ny) return -1;
        c = x - y;
      } else c = String(x).localeCompare(String(y), undefined, { numeric: true, sensitivity: "base" });
      return asc ? c : -c;
    }
    function forgetKeys() { numSep = {}; sortedCol = -1; rows().forEach(function (r) { r.__kitKeys = null; }); }
    function slice(pages) {
      return { page: page + 1, pages: pages, start: page * size, end: size ? (page + 1) * size : Infinity };
    }
    function apply() {
      if (external) {
        var total = Math.max(0, parseInt(table.getAttribute("data-kit-total"), 10) || 0);
        var want = parseInt(table.getAttribute("data-kit-page"), 10);
        var xpages = size ? Math.max(1, Math.ceil(total / size)) : 1;
        if (want > 0) page = want - 1;
        page = Math.max(0, Math.min(page, xpages - 1));
        if (pager) {
          pager.hidden = xpages < 2;
          info.textContent = "Page " + (page + 1) + " of " + xpages + ", " + total.toLocaleString() + " rows";
          prev.disabled = page === 0;
          next.disabled = page >= xpages - 1;
        }
        return xpages;
      }
      var all = rows();
      if (col >= 0 && body && (col !== sortedCol || asc !== sortedAsc)) {
        all.sort(compare).forEach(function (r) { body.appendChild(r); });
        sortedCol = col; sortedAsc = asc;
      } else if (col >= 0) all.sort(compare);
      // The search box (data-kit-filter): rows without the words are hidden, paging counts the rest.
      var words = query.toLowerCase().split(/\s+/).filter(Boolean);
      var list = all.filter(function (r) { var t = r.textContent.toLowerCase(); var hit = words.every(function (w) { return t.indexOf(w) >= 0; }); if (!hit) r.hidden = true; return hit; });
      matched = list.length;
      var pages = size ? Math.max(1, Math.ceil(list.length / size)) : 1;
      page = Math.max(0, Math.min(page, pages - 1));
      list.forEach(function (r, i) { r.hidden = !!size && (i < page * size || i >= (page + 1) * size); });
      // No rows left (a search with no match, or no data yet): the empty row shows, the totals row hides.
      var emptyRow = body && body.querySelector("tr[data-kit-empty]");
      if (emptyRow) emptyRow.hidden = list.length > 0;
      if (table.tFoot && table.tFoot.classList.contains("kit-table__total")) table.tFoot.hidden = list.length === 0;
      if (pager) {
        pager.hidden = pages < 2;
        info.textContent = "Page " + (page + 1) + " of " + pages + ", " + list.length + (words.length ? " of " + all.length : "") + " rows";
        prev.disabled = page === 0;
        next.disabled = page >= pages - 1;
      }
      if (obs) obs.takeRecords();   // our own moves are not a new set of rows
      return pages;
    }
    // On paper every matching row shows (kit.js calls this around printing).
    table.kitPrint = function (on) {
      if (external || !size) return;
      if (on) rows().forEach(function (r) { var t = r.textContent.toLowerCase(), words = query.toLowerCase().split(/\s+/).filter(Boolean); r.hidden = !words.every(function (w) { return t.indexOf(w) >= 0; }); });
      else apply();
    };
    // The search box: the page's own rows in external mode (kit:filter with the words), else here.
    table.kitFilter = function (q) {
      query = String(q || "");
      page = 0;
      if (external) table.setAttribute("data-kit-page", "1");
      var pages = apply();
      var shown = external ? null : matched;
      table.dispatchEvent(new CustomEvent("kit:filter", { bubbles: true, detail: { query: query, pages: pages, shown: shown } }));
    };
    // Sort buttons in the header cells that have none yet (also cells written later).
    function arm() {
      var headRow = table.tHead && table.tHead.rows[0];
      heads = headRow ? Array.prototype.slice.call(headRow.cells) : [];
      if (!table.hasAttribute("data-kit-sort")) return;
      heads.forEach(function (th) {
        if (th.hasAttribute("data-kit-nosort") || th.querySelector(".kit-table__sort")) return;
        var b = document.createElement("button");
        b.type = "button";
        b.className = "kit-table__sort";
        while (th.firstChild) b.appendChild(th.firstChild);
        th.appendChild(b);
        th.setAttribute("aria-sort", "none");
        b.addEventListener("click", function () {
          var i = heads.indexOf(th);
          if (i < 0) return;
          asc = col === i ? !asc : true;
          col = i;
          heads.forEach(function (h) { if (h.hasAttribute("aria-sort")) h.setAttribute("aria-sort", "none"); });
          th.setAttribute("aria-sort", asc ? "ascending" : "descending");
          page = 0;
          if (external) table.setAttribute("data-kit-page", "1");
          var pages = apply();
          table.dispatchEvent(new CustomEvent("kit:sort", { bubbles: true, detail: { column: i, key: th.getAttribute("data-key"), ascending: asc, page: 1, pages: pages, start: 0, end: size || Infinity } }));
        });
      });
    }
    arm();
    // Row selection (data-kit-select): a checkbox column, "select all" in the header, picked rows
    // marked aria-selected, a kit-bulk bar (data-kit-bulk="TABLE-ID") with the count and the actions,
    // and "kit:selection" with detail.ids (the rows' data-id), rows and count.
    if (table.hasAttribute("data-kit-select")) {
      var bulk = table.id ? document.querySelector('[data-kit-bulk="' + table.id + '"]') : null;
      var all = document.createElement("input");
      all.type = "checkbox";
      all.setAttribute("aria-label", "Select all rows");
      var selHead = table.tHead && table.tHead.rows[0];
      if (selHead && !selHead.querySelector("th.kit-table__select")) {
        var th0 = document.createElement("th");
        th0.className = "kit-table__select";
        th0.setAttribute("data-kit-nosort", "");
        th0.appendChild(all);
        selHead.insertBefore(th0, selHead.firstChild);
      }
      var boxes = function () { return rows().map(function (r) { return r.querySelector("td.kit-table__select input"); }).filter(Boolean); };
      var picked = function () { return rows().filter(function (r) { return r.getAttribute("aria-selected") === "true"; }); };
      var tell = function () {
        var p = picked(), sb = boxes().filter(function (b) { return !b.closest("tr").hidden; });
        all.checked = sb.length > 0 && sb.every(function (b) { return b.checked; });
        all.indeterminate = !all.checked && sb.some(function (b) { return b.checked; });
        if (bulk) { bulk.hidden = p.length === 0; var c = bulk.querySelector(".kit-bulk__count"); if (c) c.textContent = p.length + " selected"; }
        table.dispatchEvent(new CustomEvent("kit:selection", { bubbles: true, detail: { ids: p.map(function (r) { return r.getAttribute("data-id"); }), rows: p, count: p.length } }));
      };
      var armSelect = function () {
        rows().forEach(function (r) {
          if (r.querySelector("td.kit-table__select")) return;
          var td = document.createElement("td"), box = document.createElement("input");
          td.className = "kit-table__select";
          box.type = "checkbox";
          box.setAttribute("aria-label", "Select row");
          box.addEventListener("change", function () { r.setAttribute("aria-selected", String(box.checked)); tell(); });
          td.appendChild(box);
          r.insertBefore(td, r.firstChild);
        });
        var emptyCell = body && body.querySelector("tr[data-kit-empty] td[colspan]");
        if (emptyCell && !emptyCell.kitSpan) { emptyCell.kitSpan = true; emptyCell.colSpan = emptyCell.colSpan + 1; }
      };
      all.addEventListener("change", function () {
        boxes().forEach(function (b) { var r = b.closest("tr"); if (!r.hidden) { b.checked = all.checked; r.setAttribute("aria-selected", String(all.checked)); } });
        tell();
      });
      table.kitArmSelect = armSelect;
      table.kitSelected = picked;
      table.kitSelect = function (on) { all.checked = !!on; all.dispatchEvent(new Event("change")); };
      armSelect();
      arm();   // the header cells moved one to the right: the sort buttons learn their new places
    }
    if (size) {
      pager = document.createElement("div");
      pager.className = "kit-pager";
      pager.innerHTML = '<button class="kit-btn kit-btn--sm" type="button">Previous</button><span class="kit-pager__info" aria-live="polite"></span><button class="kit-btn kit-btn--sm" type="button">Next</button>';
      prev = pager.firstChild; info = prev.nextSibling; next = info.nextSibling;
      var wrap = table.closest(".kit-table-wrap") || table;
      wrap.parentNode.insertBefore(pager, wrap.nextSibling);
      var go = function (d) {
        page += d;
        if (external) table.setAttribute("data-kit-page", String(page + 1));
        var pages = apply();
        table.dispatchEvent(new CustomEvent("kit:page", { bubbles: true, detail: slice(pages) }));
      };
      prev.addEventListener("click", function () { go(-1); });
      next.addEventListener("click", function () { go(1); });
    }
    if (window.MutationObserver) {
      // Rows written again are sorted and paged again (the page's own rows in external mode); a
      // header row written again gets its sort buttons; a body put in later is the one used.
      obs = new MutationObserver(function (list) {
        var headChanged = false, rowsChanged = false, attrs = false;
        list.forEach(function (m) {
          if (m.type === "attributes") attrs = true;
          else if (table.tHead && table.tHead.contains(m.target)) headChanged = true;
          else rowsChanged = true;
        });
        if (table.tBodies[0] !== body) body = table.tBodies[0];
        if (rowsChanged) forgetKeys();
        if (headChanged || rowsChanged) arm();
        if (rowsChanged && table.kitArmSelect) table.kitArmSelect();
        if (external) { if (attrs || rowsChanged) apply(); }
        else if (rowsChanged) { page = 0; apply(); }
        obs.takeRecords();
      });
      obs.observe(table, external ? { childList: true, subtree: true, attributes: true, attributeFilter: ["data-kit-total", "data-kit-page"] } : { childList: true, subtree: true });
    }
    apply();
    if (obs) obs.takeRecords();
  }

  // Light and dark: <button class="kit-btn kit-btn--ghost kit-btn--icon" type="button" data-kit-theme>
  // <span data-kit-icon="moon" aria-hidden="true"></span></button>. Follows the computer's setting
  // until clicked; the choice is kept in this browser (when it may keep it) and set as data-theme
  // on <html>, which tokens.css follows. Its icon shows what a click switches to (moon, sun), its
  // label says so too. Fires "kit:theme" { theme: "light" | "dark" } on the button.
  var THEME_KEY = "kit-theme";
  function readTheme() { try { return localStorage.getItem(THEME_KEY); } catch (e) { return null; } }
  function isDark() {
    var t = document.documentElement.getAttribute("data-theme");
    if (t === "dark" || t === "light") return t === "dark";
    return !!(window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches);
  }
  var saved = readTheme();
  if (saved === "dark" || saved === "light") document.documentElement.setAttribute("data-theme", saved);
  function setupTheme(btn) {
    if (btn.kitTheme) return;
    btn.kitTheme = true;
    function showTheme() {
      var dark = isDark(), icon = btn.querySelector("[data-kit-icon]");
      if (icon) icon.setAttribute("data-kit-icon", dark ? "sun" : "moon");
      btn.setAttribute("aria-label", dark ? "Switch to the light theme" : "Switch to the dark theme");
      btn.setAttribute("title", btn.getAttribute("aria-label"));
    }
    btn.addEventListener("click", function () {
      var theme = isDark() ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", theme);
      try { localStorage.setItem(THEME_KEY, theme); } catch (e) { /* not kept: private window or blocked storage */ }
      showTheme();
      btn.dispatchEvent(new CustomEvent("kit:theme", { bubbles: true, detail: { theme: theme } }));
    });
    if (window.matchMedia) {
      var mq = matchMedia("(prefers-color-scheme: dark)");
      if (mq.addEventListener) mq.addEventListener("change", showTheme);
    }
    showTheme();
  }

  // A kit-progress bar shows its value: aria-valuenow (with aria-valuemin / aria-valuemax, else
  // 0..100) sets the width of its kit-progress__bar, also for bars written or changed later.
  function fillBar(track) {
    var bar = track.querySelector(".kit-progress__bar");
    var now = parseFloat(track.getAttribute("aria-valuenow"));
    if (!bar || isNaN(now)) return;
    var min = parseFloat(track.getAttribute("aria-valuemin")); if (isNaN(min)) min = 0;
    var max = parseFloat(track.getAttribute("aria-valuemax")); if (isNaN(max)) max = 100;
    var pct = max > min ? (now - min) / (max - min) * 100 : 0;
    bar.style.width = Math.max(0, Math.min(100, pct)) + "%";
  }
  function fillBars(root) {
    if (root.matches && root.matches(".kit-progress[aria-valuenow]")) fillBar(root);
    if (root.querySelectorAll) Array.prototype.forEach.call(root.querySelectorAll(".kit-progress[aria-valuenow]"), fillBar);
  }

  // Side panel and dialog: a button with data-kit-open="ID" opens <dialog id="ID"> (the side panel
  // or a dialog of the kit) as a modal, data-kit-close inside closes it, Escape too, and a click beside a
  // side panel. Fires "kit:open" and "kit:close" on the dialog.
  // Class names put together: a page only gets their styles when it uses the class itself.
  var DRAWER = "kit" + "-drawer", DIALOG = "kit" + "-dialog";
  function openPanel(id) {
    var d = typeof id === "string" ? document.getElementById(id) : id;
    if (!d || d.open) return;
    if (d.showModal) d.showModal(); else d.setAttribute("open", "");
    d.dispatchEvent(new CustomEvent("kit:open", { bubbles: true }));
  }
  function closePanel(id) {
    var d = typeof id === "string" ? document.getElementById(id) : id;
    if (!d || !d.open) return;
    if (d.close) d.close(); else d.removeAttribute("open");
  }
  document.addEventListener("click", function (e) {
    var t = e.target;
    var opener = t.closest && t.closest("[data-kit-open]");
    if (opener) { openPanel(opener.getAttribute("data-kit-open")); return; }
    var closer = t.closest && t.closest("[data-kit-close]");
    if (closer) { closePanel(closer.closest("dialog")); return; }
    if (t.matches && t.matches("dialog[open]") && t.classList.contains(DRAWER)) { closePanel(t); return; }   // the backdrop
    if (t.closest && t.closest("[data-kit-print]")) window.print();
  });
  document.addEventListener("close", function (e) {
    if (e.target.matches && e.target.matches("dialog") && (e.target.classList.contains(DRAWER) || e.target.classList.contains(DIALOG))) e.target.dispatchEvent(new CustomEvent("kit:close", { bubbles: true }));
  }, true);

  // Toasts: KitUI.toast("Saved", { tone: "ok" | "warn" | "error", ms: 4000 }), read out by screen readers.
  function toast(text, opts) {
    opts = opts || {};
    var region = toastRegion();
    var t = document.createElement("div");
    t.className = "kit-toast" + (/^(ok|warn|error)$/.test(opts.tone || "") ? " kit-toast--" + opts.tone : "");
    t.textContent = String(text);
    region.appendChild(t);
    var ms = opts.ms || (opts.tone === "error" ? 8000 : 4000);
    setTimeout(function () {
      t.classList.add("is-leaving");
      setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 400);
    }, ms);
    return t;
  }

  // Info tip: <button class="kit-tip" type="button" aria-label="How it is counted" data-kit-tip="TEXT">.
  var tipCount = 0;
  function setupTip(btn) {
    if (btn.kitTip) return;
    btn.kitTip = true;
    var bubble = document.createElement("span");
    bubble.className = "kit-tip__bubble";
    bubble.setAttribute("role", "tooltip");
    bubble.id = "kit-tip-" + (++tipCount);
    bubble.hidden = true;
    bubble.textContent = btn.getAttribute("data-kit-tip");
    btn.appendChild(bubble);
    btn.setAttribute("aria-describedby", bubble.id);
    var show = function () {
      bubble.textContent = btn.getAttribute("data-kit-tip"); bubble.hidden = false;
      bubble.classList.remove("is-left", "is-right");
      var r = bubble.getBoundingClientRect();
      if (r.left < 8) bubble.classList.add("is-left"); else if (r.right > window.innerWidth - 8) bubble.classList.add("is-right");
    };
    var hide = function () { bubble.hidden = true; };
    btn.addEventListener("mouseenter", show);
    btn.addEventListener("focus", show);
    btn.addEventListener("mouseleave", function () { if (document.activeElement !== btn) hide(); });
    btn.addEventListener("blur", hide);
    btn.addEventListener("keydown", function (e) { if (e.key === "Escape") hide(); });
    btn.addEventListener("click", function (e) { e.preventDefault(); if (bubble.hidden) show(); else hide(); });
  }

  // Several values: <select multiple class="kit-select" data-kit-multi aria-label="Country">. The kit
  // draws a field with a list of check boxes and a search; nothing ticked means all. The select
  // keeps the choice (its options' selected) and fires "change"; "kit:multi" has detail.values.
  function setupMulti(select) {
    if (select.kitMulti) return;
    select.kitMulti = true;
    var label = select.getAttribute("aria-label") || (select.labels && select.labels[0] ? select.labels[0].textContent.trim() : "") || "Values";
    var wrap = document.createElement("div");
    wrap.className = "kit-multi";
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "kit-input kit-multi__button";
    btn.setAttribute("aria-haspopup", "true");
    btn.setAttribute("aria-expanded", "false");
    var panel = document.createElement("div");
    panel.className = "kit-multi__panel";
    panel.hidden = true;
    panel.innerHTML = '<input class="kit-input" type="search" placeholder="Search"><ul class="kit-multi__list"></ul><div class="kit-multi__actions"><button class="kit-btn kit-btn--sm kit-btn--ghost" type="button" data-all>Select all</button><button class="kit-btn kit-btn--sm kit-btn--ghost" type="button" data-none>Clear</button></div>';
    var search = panel.querySelector("input"), list = panel.querySelector("ul");
    search.setAttribute("aria-label", "Search " + label);
    select.parentNode.insertBefore(wrap, select);
    wrap.appendChild(select);
    wrap.appendChild(btn);
    wrap.appendChild(panel);
    select.hidden = true;
    function chosen() { return Array.prototype.filter.call(select.options, function (o) { return o.selected; }); }
    function showChoice() {
      var c = chosen(), n = select.options.length;
      btn.textContent = label + ": " + (!c.length || c.length === n ? "All" : c.length === 1 ? c[0].textContent : c.length + " selected");
      wrap.classList.toggle("is-active", c.length > 0 && c.length < n);
    }
    function build() {
      list.innerHTML = "";
      Array.prototype.forEach.call(select.options, function (o, i) {
        var li = document.createElement("li"), lab = document.createElement("label"), box = document.createElement("input");
        box.type = "checkbox";
        box.checked = o.selected;
        box.addEventListener("change", function () { o.selected = box.checked; changed(); });
        lab.appendChild(box);
        lab.appendChild(document.createTextNode(o.textContent));
        li.appendChild(lab);
        li.setAttribute("data-i", i);
        list.appendChild(li);
      });
      filterList();
      showChoice();
    }
    function filterList() {
      var q = search.value.trim().toLowerCase();
      Array.prototype.forEach.call(list.children, function (li) { li.hidden = q && li.textContent.toLowerCase().indexOf(q) < 0; });
    }
    function changed() {
      showChoice();
      select.dispatchEvent(new Event("change", { bubbles: true }));
      select.dispatchEvent(new CustomEvent("kit:multi", { bubbles: true, detail: { values: chosen().map(function (o) { return o.value; }) } }));
    }
    function setAll(on) {
      Array.prototype.forEach.call(select.options, function (o) { o.selected = on; });
      Array.prototype.forEach.call(list.querySelectorAll("input"), function (b) { b.checked = on; });
      changed();
    }
    function toggle(open) {
      panel.hidden = !open;
      btn.setAttribute("aria-expanded", String(open));
      if (open) { search.value = ""; filterList(); search.focus(); }
    }
    btn.addEventListener("click", function () { toggle(panel.hidden); });
    search.addEventListener("input", filterList);
    panel.querySelector("[data-all]").addEventListener("click", function () { setAll(true); });
    panel.querySelector("[data-none]").addEventListener("click", function () { setAll(false); });
    wrap.addEventListener("keydown", function (e) { if (e.key === "Escape" && !panel.hidden) { toggle(false); btn.focus(); } });
    document.addEventListener("click", function (e) { if (!panel.hidden && !wrap.contains(e.target)) toggle(false); });
    if (window.MutationObserver) new MutationObserver(build).observe(select, { childList: true });
    build();
  }

  // Period: <div class="kit-range" data-kit-range data-value="30d" aria-label="Period">. Buttons for the
  // periods (data-presets="7d,30d,week,month,quarter,year,all,custom" chooses which), date fields for
  // custom; "kit:range" has detail.preset, detail.from and detail.to (yyyy-mm-dd, both included; empty
  // for all). The week starts on the day Settings give (--kit-week-start in kit.css).
  var RANGE_NAMES = { "7d": "Last 7 days", "30d": "Last 30 days", "90d": "Last 90 days", week: "This week", month: "This month", quarter: "This quarter", year: "This year", all: "All", custom: "Custom" };
  function isoDay(d) { return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2); }
  function rangeOf(preset) {
    var now = new Date(), today = new Date(now.getFullYear(), now.getMonth(), now.getDate()), from = null;
    var days = /^(\d+)d$/.exec(preset);
    if (days) { from = new Date(today); from.setDate(from.getDate() - (parseInt(days[1], 10) - 1)); }
    else if (preset === "week") {
      var start = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--kit-week-start"), 10);
      if (isNaN(start)) start = 1;
      from = new Date(today); from.setDate(from.getDate() - ((today.getDay() - start + 7) % 7));
    }
    else if (preset === "month") from = new Date(today.getFullYear(), today.getMonth(), 1);
    else if (preset === "quarter") from = new Date(today.getFullYear(), Math.floor(today.getMonth() / 3) * 3, 1);
    else if (preset === "year") from = new Date(today.getFullYear(), 0, 1);
    return from ? { from: isoDay(from), to: isoDay(today) } : { from: "", to: "" };
  }
  function setupRange(el) {
    if (el.kitRange) return;
    el.kitRange = true;
    var presets = (el.getAttribute("data-presets") || "7d,30d,month,quarter,year,all,custom").split(",").map(function (p) { return p.trim(); }).filter(function (p) { return RANGE_NAMES[p] || /^\d+d$/.test(p); });
    if (el.getAttribute("aria-label") && !el.getAttribute("role")) el.setAttribute("role", "group");
    var seg = document.createElement("div");
    seg.className = "kit-segmented";
    seg.setAttribute("role", "group");
    seg.setAttribute("aria-label", (el.getAttribute("aria-label") || "Period") + " presets");
    var custom = document.createElement("span");
    custom.className = "kit-range__custom";
    custom.hidden = true;
    custom.innerHTML = '<input class="kit-input" type="date" aria-label="From"><span aria-hidden="true">-</span><input class="kit-input" type="date" aria-label="To">';
    var fromIn = custom.children[0], toIn = custom.children[2];
    presets.forEach(function (p) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = RANGE_NAMES[p] || ("Last " + parseInt(p, 10) + " days");
      b.setAttribute("data-preset", p);
      b.setAttribute("aria-pressed", "false");
      b.addEventListener("click", function () { choose(p); });
      seg.appendChild(b);
    });
    el.appendChild(seg);
    el.appendChild(custom);
    function send(preset, r) {
      el.setAttribute("data-from", r.from);
      el.setAttribute("data-to", r.to);
      el.classList.toggle("is-active", preset !== "all");
      el.dispatchEvent(new CustomEvent("kit:range", { bubbles: true, detail: { preset: preset, from: r.from, to: r.to } }));
    }
    function choose(p, quiet) {
      el.setAttribute("data-value", p);
      Array.prototype.forEach.call(seg.children, function (b) { b.setAttribute("aria-pressed", String(b.getAttribute("data-preset") === p)); });
      custom.hidden = p !== "custom";
      if (p === "custom") { if (!quiet) fromIn.focus(); if (fromIn.value || toIn.value) send(p, { from: fromIn.value, to: toIn.value }); return; }
      var r = rangeOf(p);
      if (quiet) { el.setAttribute("data-from", r.from); el.setAttribute("data-to", r.to); el.classList.toggle("is-active", p !== "all"); } else send(p, r);
    }
    var onDates = function () { if (fromIn.value && toIn.value && fromIn.value > toIn.value) { var x = fromIn.value; fromIn.value = toIn.value; toIn.value = x; } send("custom", { from: fromIn.value, to: toIn.value }); };
    fromIn.addEventListener("change", onDates);
    toIn.addEventListener("change", onDates);
    var start = el.getAttribute("data-value");
    choose(presets.indexOf(start) >= 0 ? start : (presets.indexOf("all") >= 0 ? "all" : presets[0]), true);
    el.kitRangeOf = rangeOf;
  }

  // Table search: <input class="kit-input kit-table-search" type="search" data-kit-filter="TABLE-ID"
  // aria-label="Search the table">; hides rows without the words (sorting and paging go on).
  var filterTimer = 0;
  document.addEventListener("input", function (e) {
    var input = e.target;
    if (!input.matches || !input.matches("[data-kit-filter]")) return;
    clearTimeout(filterTimer);
    filterTimer = setTimeout(function () {
      var table = document.getElementById(input.getAttribute("data-kit-filter"));
      if (!table) return;
      if (!table.kitFilter) setupTable(table);
      table.kitFilter(input.value);
    }, 120);
  });

  // When the data is from: <span class="kit-stamp" data-kit-stamp="2026-10-09T14:00"> or
  // data-kit-stamp-of="GLOBAL" (the time the helper program gives a data block: window.kitDataAsOf).
  // Shows "Data as of 9 Oct 2026, 14:00 (2 hours ago)"; data-kit-prefix changes the first words.
  function ago(ms) {
    var s = Math.round((ms - Date.now()) / 1000), a = Math.abs(s);
    var unit = a < 60 ? ["second", s] : a < 3600 ? ["minute", Math.round(s / 60)] : a < 86400 ? ["hour", Math.round(s / 3600)] : ["day", Math.round(s / 86400)];
    try { return new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }).format(unit[1], unit[0]); } catch (e) { return ""; }
  }
  function showStamp(el, when) {
    var v = when || el.getAttribute("data-kit-stamp");
    var of = el.getAttribute("data-kit-stamp-of");
    if (!v && of && window.kitDataAsOf) v = window.kitDataAsOf[of];
    var d = v ? new Date(v) : null;
    if (!d || isNaN(d.getTime())) return;
    if (when) el.setAttribute("data-kit-stamp", d.toISOString());
    var text;
    try { text = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(d); } catch (e) { text = d.toLocaleString(); }
    el.textContent = (el.getAttribute("data-kit-prefix") || "Data as of") + " " + text + " (" + ago(d.getTime()) + ")";
    el.setAttribute("title", d.toISOString());
  }
  function showStamps() { Array.prototype.forEach.call(document.querySelectorAll(".kit-stamp, [data-kit-stamp], [data-kit-stamp-of]"), function (el) { showStamp(el); }); }
  setInterval(showStamps, 60000);

  // Printing: in the light theme, and a paged table prints every row that matches (not one page).
  var printTheme = null;
  window.addEventListener("beforeprint", function () {
    printTheme = document.documentElement.getAttribute("data-theme");
    document.documentElement.setAttribute("data-theme", "light");
    Array.prototype.forEach.call(document.querySelectorAll("table"), function (t) { if (t.kitPrint) t.kitPrint(true); });
  });
  window.addEventListener("afterprint", function () {
    if (printTheme) document.documentElement.setAttribute("data-theme", printTheme); else document.documentElement.removeAttribute("data-theme");
    Array.prototype.forEach.call(document.querySelectorAll("table"), function (t) { if (t.kitPrint) t.kitPrint(false); });
  });

  // Menu (from kokonutui profile-dropdown): a button with data-kit-menu opens the kit-menu__list next to
  // it; arrow keys move, Escape or a click beside it closes; "kit:menu" with detail.value on the kit-menu.
  function menuList(btn) { var m = btn.closest(".kit-menu"); return m ? m.querySelector(".kit-menu__list") : btn.nextElementSibling; }
  function menuItems(list) { return Array.prototype.slice.call(list.querySelectorAll(".kit-menu__item:not([disabled])")); }
  function closeMenus(except) {
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-menu][aria-expanded=true]"), function (b) {
      if (b === except) return;
      b.setAttribute("aria-expanded", "false");
      var l = menuList(b); if (l) l.hidden = true;
    });
  }
  document.addEventListener("click", function (e) {
    var btn = e.target.closest && e.target.closest("[data-kit-menu]");
    if (btn) {
      var list = menuList(btn), open = btn.getAttribute("aria-expanded") === "true";
      closeMenus(btn);
      btn.setAttribute("aria-expanded", String(!open));
      if (list) { list.hidden = open; if (!open) { var first = menuItems(list)[0]; if (first) first.focus(); } }
      return;
    }
    var item = e.target.closest && e.target.closest(".kit-menu__item");
    if (item) {
      var menu = item.closest(".kit-menu");
      var b2 = menu && menu.querySelector("[data-kit-menu]");
      closeMenus();
      if (menu) menu.dispatchEvent(new CustomEvent("kit:menu", { bubbles: true, detail: { value: item.getAttribute("data-value") || item.textContent.trim() } }));
      if (b2) b2.focus();
      return;
    }
    if (!(e.target.closest && e.target.closest(".kit-menu__list"))) closeMenus();
  });
  document.addEventListener("keydown", function (e) {
    var list = e.target.closest && e.target.closest(".kit-menu__list");
    if (!list) return;
    var items = menuItems(list), i = items.indexOf(document.activeElement);
    if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); var n = items[(i + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length]; if (n) n.focus(); }
    else if (e.key === "Home" || e.key === "End") { e.preventDefault(); var h = items[e.key === "Home" ? 0 : items.length - 1]; if (h) h.focus(); }
    else if (e.key === "Escape" || e.key === "Tab") { var box = list.closest(".kit-menu"), mb = box ? box.querySelector("[data-kit-menu]") : (list.previousElementSibling && list.previousElementSibling.hasAttribute("data-kit-menu") ? list.previousElementSibling : null); closeMenus(); if (e.key === "Escape" && mb) mb.focus(); }
  });

  // Icon toolbar (from kokonutui toolbar): data-kit-iconbar="single" (one pressed) or "multiple";
  // arrow keys move between the buttons; "kit:select" with detail.value and detail.values.
  function setupIconbar(bar) {
    if (bar.kitIconbar) return;
    bar.kitIconbar = true;
    var single = bar.getAttribute("data-kit-iconbar") !== "multiple";
    var items = function () { return Array.prototype.slice.call(bar.querySelectorAll(".kit-iconbar__item")); };
    var val = function (b) { return b.getAttribute("data-value") || b.getAttribute("aria-label") || b.textContent.trim(); };
    bar.addEventListener("click", function (e) {
      var b = e.target.closest(".kit-iconbar__item");
      if (!b || !bar.contains(b)) return;
      if (single) items().forEach(function (x) { x.setAttribute("aria-pressed", String(x === b)); });
      else b.setAttribute("aria-pressed", String(b.getAttribute("aria-pressed") !== "true"));
      var on = items().filter(function (x) { return x.getAttribute("aria-pressed") === "true"; }).map(val);
      bar.dispatchEvent(new CustomEvent("kit:select", { bubbles: true, detail: { value: val(b), values: on } }));
    });
    bar.addEventListener("keydown", function (e) {
      if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
      var list = items(), i = list.indexOf(document.activeElement);
      if (i < 0) return;
      e.preventDefault();
      list[(i + (e.key === "ArrowRight" ? 1 : -1) + list.length) % list.length].focus();
    });
  }

  // Avatars (from kokonutui team-selector): data-kit-avatar="NAME" writes the initials and gives every
  // name its own chart colour (the same name always the same colour); an <img> inside stays.
  function setupAvatar(el) {
    var name = (el.getAttribute("data-kit-avatar") || "").trim();
    if (!name || el.kitAvatar === name) return;
    el.kitAvatar = name;
    var words = name.split(/\s+/).filter(Boolean);
    if (!el.querySelector("img")) el.textContent = ((words[0] || "").charAt(0) + (words.length > 1 ? words[words.length - 1].charAt(0) : "")).toUpperCase();
    var h = 0;
    for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) | 0;
    el.style.setProperty("--kit-avatar-color", "var(--kit-chart-" + ((Math.abs(h) % 6) + 1) + ")");
    el.setAttribute("title", name);
    if (!el.hasAttribute("aria-label")) { el.setAttribute("role", "img"); el.setAttribute("aria-label", name); }
  }

  // Two values on one slider: data-kit-slider-range with data-min, data-max, data-step, data-from, data-to;
  // "kit:slide" with detail.from and detail.to; the values show under it.
  function setupSliderRange(el) {
    if (el.kitSlider) return;
    el.kitSlider = true;
    if (el.getAttribute("aria-label") && !el.getAttribute("role")) el.setAttribute("role", "group");
    var num = function (n, d) { var v = parseFloat(el.getAttribute(n)); return isNaN(v) ? d : v; };
    var min = num("data-min", 0), max = num("data-max", 100), step = num("data-step", 1), name = el.getAttribute("aria-label") || "Range";
    var fill = document.createElement("span");
    fill.className = "kit-slider-range__fill";
    el.appendChild(fill);
    var mk = function (value, label) {
      var i = document.createElement("input");
      i.type = "range"; i.className = "kit-slider"; i.min = min; i.max = max; i.step = step; i.value = value;
      i.setAttribute("aria-label", label);
      el.appendChild(i);
      return i;
    };
    var a = mk(num("data-from", min), "Lowest " + name), b = mk(num("data-to", max), "Highest " + name);
    var out = document.createElement("div");
    out.className = "kit-slider__value";
    out.setAttribute("aria-live", "polite");
    el.parentNode.insertBefore(out, el.nextSibling);
    var draw = function (send) {
      var lo = Math.min(+a.value, +b.value), hi = Math.max(+a.value, +b.value);
      fill.style.left = ((lo - min) / (max - min || 1)) * 100 + "%";
      fill.style.width = ((hi - lo) / (max - min || 1)) * 100 + "%";
      out.textContent = lo.toLocaleString() + " - " + hi.toLocaleString();
      el.setAttribute("data-from", lo); el.setAttribute("data-to", hi);
      if (send) el.dispatchEvent(new CustomEvent("kit:slide", { bubbles: true, detail: { from: lo, to: hi } }));
    };
    a.addEventListener("input", function () { draw(true); });
    b.addEventListener("input", function () { draw(true); });
    draw(false);
  }

  // Tags: data-kit-tags (data-name for the form field, data-tags="a,b" to start with, list="DATALIST-ID" for
  // suggestions); Enter or a comma adds, Backspace in an empty box removes the last; "kit:tags" with detail.values.
  function setupTags(el) {
    if (el.kitTags) return;
    el.kitTags = true;
    if (el.getAttribute("aria-label") && !el.getAttribute("role")) el.setAttribute("role", "group");
    var values = (el.getAttribute("data-tags") || "").split(",").map(function (v) { return v.trim(); }).filter(Boolean);
    var input = document.createElement("input");
    input.className = "kit-tags__input";
    input.type = "text";
    input.setAttribute("aria-label", el.getAttribute("aria-label") || "Add a tag");
    if (el.getAttribute("list")) input.setAttribute("list", el.getAttribute("list"));
    var hidden = null;
    if (el.getAttribute("data-name")) { hidden = document.createElement("input"); hidden.type = "hidden"; hidden.name = el.getAttribute("data-name"); el.appendChild(hidden); }
    el.appendChild(input);
    function draw(send) {
      Array.prototype.forEach.call(el.querySelectorAll(".kit-tags__tag"), function (t) { t.parentNode.removeChild(t); });
      values.forEach(function (v, i) {
        var t = document.createElement("span"); t.className = "kit-tags__tag"; t.textContent = v;
        var x = document.createElement("button"); x.type = "button"; x.className = "kit-tags__remove"; x.setAttribute("aria-label", "Remove " + v); x.textContent = String.fromCharCode(215);
        x.addEventListener("click", function () { values.splice(i, 1); draw(true); input.focus(); });
        t.appendChild(x);
        el.insertBefore(t, input);
      });
      if (hidden) hidden.value = values.join(",");
      el.setAttribute("data-tags", values.join(","));
      if (send) el.dispatchEvent(new CustomEvent("kit:tags", { bubbles: true, detail: { values: values.slice() } }));
    }
    function add(text) {
      var v = text.replace(/,/g, " ").trim();
      if (v && values.indexOf(v) < 0) { values.push(v); draw(true); }
      input.value = "";
    }
    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === ",") { e.preventDefault(); add(input.value); }
      else if (e.key === "Backspace" && !input.value && values.length) { values.pop(); draw(true); }
    });
    input.addEventListener("change", function () { if (input.value.indexOf(",") < 0 && input.value) add(input.value); });
    el.addEventListener("click", function (e) { if (e.target === el) input.focus(); });
    draw(false);
  }

  // Board: drag a kit-board__card to another data-kit-board list, or focus it and press Alt with an arrow
  // key (left and right: the next list, up and down: the order); "kit:move" with detail.id, from, to and index.
  var dragCard = null, dragFrom = null;
  function boardLists(card) { var b = card.closest(".kit-board"); return b ? Array.prototype.slice.call(b.querySelectorAll("[data-kit-board]")) : []; }
  function moved(card, from) {
    var to = card.parentNode;
    card.dispatchEvent(new CustomEvent("kit:move", { bubbles: true, detail: { id: card.getAttribute("data-id"), from: from.getAttribute("data-kit-board"), to: to.getAttribute("data-kit-board"), index: Array.prototype.indexOf.call(to.children, card) } }));
  }
  function setupBoardCard(card) {
    if (card.kitCard) return;
    card.kitCard = true;
    card.setAttribute("draggable", "true");
    if (!card.hasAttribute("tabindex")) card.tabIndex = 0;
    card.addEventListener("dragstart", function (e) { dragCard = card; dragFrom = card.parentNode; card.classList.add("is-dragging"); try { e.dataTransfer.setData("text/plain", card.getAttribute("data-id") || ""); e.dataTransfer.effectAllowed = "move"; } catch (x) { /* older browsers */ } });
    card.addEventListener("dragend", function () { card.classList.remove("is-dragging"); Array.prototype.forEach.call(document.querySelectorAll(".kit-board__list.is-over"), function (l) { l.classList.remove("is-over"); }); });
    card.addEventListener("keydown", function (e) {
      if (!e.altKey || !/^Arrow/.test(e.key)) return;
      e.preventDefault();
      var from = card.parentNode, lists = boardLists(card), li = lists.indexOf(from);
      if (e.key === "ArrowUp" && card.previousElementSibling) from.insertBefore(card, card.previousElementSibling);
      else if (e.key === "ArrowDown" && card.nextElementSibling) from.insertBefore(card.nextElementSibling, card);
      else if ((e.key === "ArrowLeft" || e.key === "ArrowRight") && lists.length) {
        var to = lists[li + (e.key === "ArrowRight" ? 1 : -1)];
        if (!to) return;
        to.appendChild(card);
      } else return;
      card.focus();
      moved(card, from);
    });
  }
  function setupBoardList(list) {
    if (list.kitList) return;
    list.kitList = true;
    list.addEventListener("dragover", function (e) {
      if (!dragCard) return;
      e.preventDefault();
      list.classList.add("is-over");
      var after = Array.prototype.filter.call(list.children, function (c) { return c !== dragCard && c.getBoundingClientRect().top + c.offsetHeight / 2 > e.clientY; })[0];
      if (after) list.insertBefore(dragCard, after); else list.appendChild(dragCard);
    });
    list.addEventListener("dragleave", function (e) { if (!list.contains(e.relatedTarget)) list.classList.remove("is-over"); });
    list.addEventListener("drop", function (e) { e.preventDefault(); list.classList.remove("is-over"); if (dragCard) { moved(dragCard, dragFrom); dragCard = null; } });
  }

  // Calendar month: data-kit-calendar with data-month="YYYY-MM" (default this month); KitUI.calendar(el,
  // { month, events: [{ date, title, tone }] }) sets the events; "kit:day" (detail.date, events) and "kit:month".
  function calendarDraw(el) {
    var st = el.kitCal, y = st.year, m = st.month;
    var start = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--kit-week-start"), 10);
    if (isNaN(start)) start = 1;
    var first = new Date(y, m, 1), lead = (first.getDay() - start + 7) % 7, today = isoDay(new Date());
    var title;
    try { title = new Intl.DateTimeFormat(undefined, { month: "long", year: "numeric" }).format(first); } catch (e) { title = y + "-" + (m + 1); }
    el.innerHTML = "";
    var head = document.createElement("div");
    head.className = "kit-calendar__head";
    head.innerHTML = '<button class="kit-btn kit-btn--sm kit-btn--ghost" type="button" data-step="-1">Previous</button><h3 class="kit-calendar__title" aria-live="polite"></h3><button class="kit-btn kit-btn--sm kit-btn--ghost" type="button" data-step="1">Next</button>';
    head.querySelector("h3").textContent = title;
    el.appendChild(head);
    var grid = document.createElement("div");
    grid.className = "kit-calendar__grid";
    grid.setAttribute("role", "group");
    grid.setAttribute("aria-label", title);
    var fmt = null;
    try { fmt = new Intl.DateTimeFormat(undefined, { weekday: "short" }); } catch (e) { fmt = null; }
    for (var d = 0; d < 7; d++) {
      var dow = document.createElement("div");
      dow.className = "kit-calendar__dow";
      dow.setAttribute("aria-hidden", "true");
      var ref = new Date(2024, 0, 7 + ((start + d) % 7));   // 7 Jan 2024 was a Sunday
      dow.textContent = fmt ? fmt.format(ref) : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][ref.getDay()];
      grid.appendChild(dow);
    }
    var cells = Math.ceil((lead + new Date(y, m + 1, 0).getDate()) / 7) * 7;
    for (var c = 0; c < cells; c++) {
      var day = new Date(y, m, 1 - lead + c), iso = isoDay(day);
      var b = document.createElement("button");
      b.type = "button";
      b.className = "kit-calendar__day" + (day.getMonth() !== m ? " is-other" : "") + (iso === today ? " is-today" : "");
      b.setAttribute("data-date", iso);
      var num = document.createElement("span"); num.className = "kit-calendar__num"; num.textContent = day.getDate(); b.appendChild(num);
      var evs = (st.events || []).filter(function (ev) { return String(ev.date).slice(0, 10) === iso; });
      evs.slice(0, 3).forEach(function (ev) {
        var s = document.createElement("span");
        s.className = "kit-calendar__event" + (/^(ok|warn|error)$/.test(ev.tone || "") ? " kit-calendar__event--" + ev.tone : "");
        s.textContent = ev.title;
        b.appendChild(s);
      });
      if (evs.length > 3) { var more = document.createElement("span"); more.className = "kit-calendar__event"; more.textContent = "+" + (evs.length - 3); b.appendChild(more); }
      var label;
      try { label = new Intl.DateTimeFormat(undefined, { dateStyle: "full" }).format(day); } catch (e) { label = iso; }
      b.setAttribute("aria-label", label + (evs.length ? ", " + evs.length + " item" + (evs.length > 1 ? "s" : "") : ""));
      grid.appendChild(b);
    }
    el.appendChild(grid);
  }
  function setupCalendar(el, opts) {
    var now = new Date(), mm = /^(\d{4})-(\d{2})$/.exec((opts && opts.month) || el.getAttribute("data-month") || "");
    if (!el.kitCal) {
      el.kitCal = { year: mm ? +mm[1] : now.getFullYear(), month: mm ? +mm[2] - 1 : now.getMonth(), events: [] };
      el.addEventListener("click", function (e) {
        var stepBtn = e.target.closest("[data-step]");
        if (stepBtn) {
          var d = new Date(el.kitCal.year, el.kitCal.month + parseInt(stepBtn.getAttribute("data-step"), 10), 1);
          el.kitCal.year = d.getFullYear(); el.kitCal.month = d.getMonth();
          calendarDraw(el);
          el.dispatchEvent(new CustomEvent("kit:month", { bubbles: true, detail: { month: d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) } }));
          return;
        }
        var day = e.target.closest(".kit-calendar__day");
        if (day) {
          var date = day.getAttribute("data-date");
          el.dispatchEvent(new CustomEvent("kit:day", { bubbles: true, detail: { date: date, events: (el.kitCal.events || []).filter(function (ev) { return String(ev.date).slice(0, 10) === date; }) } }));
        }
      });
    }
    if (opts) {
      if (mm) { el.kitCal.year = +mm[1]; el.kitCal.month = +mm[2] - 1; }
      if (opts.events) el.kitCal.events = opts.events;
    }
    calendarDraw(el);
  }

  // App shell: on a narrow screen the side navigation (kit-shell__nav) folds away; the button with
  // data-kit-shell-menu (aria-controls="NAV-ID") opens and closes it; a click on a link or Escape closes it.
  function setupShellMenu(btn) {
    if (btn.kitShell) return;
    btn.kitShell = true;
    var nav = document.getElementById(btn.getAttribute("aria-controls") || "") || (btn.closest(".kit-shell") || document).querySelector(".kit-shell__nav");
    if (!nav) return;
    var set = function (open) { nav.classList.toggle("is-open", open); btn.setAttribute("aria-expanded", String(open)); };
    btn.addEventListener("click", function () { set(!nav.classList.contains("is-open")); });
    nav.addEventListener("click", function (e) { if (e.target.closest && e.target.closest("a")) set(false); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && nav.classList.contains("is-open")) { set(false); btn.focus(); } });
    set(false);
  }

  // Numbers, percentages, dates and times the same on every page (the page's language, html lang,
  // decides the separators): KitUI.format.number(v, { decimals }), percent(v, decimals) (v as 0..100;
  // one decimal unless whole), date(v, { time }) -> "9 Oct 2026" / "9 Oct 2026, 14:00", relative(v)
  // -> "2 hours ago"; "-" for what is not a number or date.
  function pageLang() { return document.documentElement.lang || undefined; }
  var format = {
    number: function (v, opts) {
      var n = Number(v);
      if (v === null || v === undefined || v === "" || !isFinite(n)) return "-";
      var d = opts && opts.decimals;
      return n.toLocaleString(pageLang(), d === undefined ? { maximumFractionDigits: 2 } : { minimumFractionDigits: d, maximumFractionDigits: d });
    },
    percent: function (v, decimals) {
      var n = Number(v);
      if (v === null || v === undefined || v === "" || !isFinite(n)) return "-";
      var d = decimals === undefined ? (Math.round(n) === n ? 0 : 1) : decimals;
      return n.toLocaleString(pageLang(), { minimumFractionDigits: d, maximumFractionDigits: d }) + "%";
    },
    date: function (v, opts) {
      var d = v instanceof Date ? v : new Date(v);
      if (!v || isNaN(d.getTime())) return "-";
      // Day, month, year in that order whatever the language ("9 Oct 2026"), the month's name in the page's language.
      var month;
      try { month = new Intl.DateTimeFormat(pageLang(), { month: "short" }).format(d).replace(/\.$/, ""); } catch (e) { month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getMonth()]; }
      var text = d.getDate() + " " + month + " " + d.getFullYear();
      if (opts && opts.time) text += ", " + ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
      return text;
    },
    relative: function (v) { var d = v instanceof Date ? v : new Date(v); return !v || isNaN(d.getTime()) ? "-" : ago(d.getTime()); }
  };

  // Loading text that changes (from kokonutui dynamic text, toned down): data-kit-cycle="First|Second|Third"
  // on a kit-loading__text shows the next line every 2.4 seconds while it is on the page.
  function setupCycle(el) {
    if (el.kitCycle) return;
    el.kitCycle = true;
    var lines = (el.getAttribute("data-kit-cycle") || "").split("|").map(function (l) { return l.trim(); }).filter(Boolean);
    if (lines.length < 2) return;
    var i = 0;
    el.textContent = lines[0];
    var timer = setInterval(function () {
      if (!document.body.contains(el)) { clearInterval(timer); return; }
      i = (i + 1) % lines.length;
      el.textContent = lines[i];
    }, 2400);
  }

  // The parts that need setting up, in what the page has now or writes later.
  var PARTS = [[".kit-tip[data-kit-tip], [data-kit-tip]", setupTip], ["select[data-kit-multi]", setupMulti], ["[data-kit-range]", setupRange],
    ["[data-kit-iconbar]", setupIconbar], ["[data-kit-avatar]", setupAvatar], ["[data-kit-slider-range]", setupSliderRange], ["[data-kit-tags]", setupTags],
    ["[data-kit-board] > *", setupBoardCard], ["[data-kit-board]", setupBoardList], ["[data-kit-calendar]", function (el) { if (!el.kitCal) setupCalendar(el); }], ["[data-kit-cycle]", setupCycle],
    [".kit-avatars[aria-label], .kit-board[aria-label]", function (el) { if (!el.getAttribute("role")) el.setAttribute("role", "group"); }],
    // Also for what a page writes after it loaded (a search box in a panel drawn later).
    ["[data-kit-hold]", setupHold], ["[data-kit-search]", setupSearch], ["[data-kit-drop]", setupDrop], ["[data-kit-theme]", setupTheme],
    [".kit-tabs--animated", function (g) { setupSlider(g, ".kit-tab", "aria-selected", "kit-tabs__indicator"); }],
    [".kit-segmented--animated", function (g) { setupSlider(g, "button", "aria-pressed", "kit-segmented__indicator"); }],
    ['[role="tablist"], .kit-tabs', setupTablist], ["[data-kit-shell-menu]", setupShellMenu]];
  function setupParts(root) {
    PARTS.forEach(function (p) {
      if (root.matches && root.matches(p[0])) safe(p[1], root);
      if (root.querySelectorAll) Array.prototype.forEach.call(root.querySelectorAll(p[0]), function (el) { safe(p[1], el); });
    });
    if (root.matches && root.matches(".kit-stamp, [data-kit-stamp], [data-kit-stamp-of]")) showStamp(root);
    if (root.querySelectorAll) Array.prototype.forEach.call(root.querySelectorAll(".kit-stamp, [data-kit-stamp], [data-kit-stamp-of]"), function (el) { showStamp(el); });
  }

  window.KitUI = {
    toast: toast,
    format: format,
    open: openPanel,
    close: closePanel,
    stamp: function (el, when) { showStamp(typeof el === "string" ? document.querySelector(el) : el, when); },
    range: function (preset) { return rangeOf(preset); },
    calendar: function (el, opts) { setupCalendar(typeof el === "string" ? document.querySelector(el) : el, opts || {}); },
  };

  var TABLES = "table[data-kit-sort], table[data-kit-pages]";
  function setupTables(root) {
    if (root.matches && root.matches(TABLES)) safe(setupTable, root);
    if (root.querySelectorAll) Array.prototype.forEach.call(root.querySelectorAll(TABLES), function (el) { safe(setupTable, el); });
  }

  function toastRegion() {
    var region = document.querySelector(".kit-toasts");
    if (!region) {
      region = document.createElement("div");
      region.className = "kit-toasts";
      region.setAttribute("role", "status");
      region.setAttribute("aria-live", "polite");
      document.body.appendChild(region);
    }
    return region;
  }
  // Tabs (role="tablist"): the arrow keys, Home and End move between the tabs and select; one tab stop.
  function setupTablist(group) {
    if (group.kitTabs) return;
    group.kitTabs = true;
    var tabs = function () { return Array.prototype.slice.call(group.querySelectorAll('[role="tab"], .kit-tab')); };
    var roving = function () { var list = tabs(), cur = list.filter(function (b) { return b.getAttribute("aria-selected") === "true"; })[0] || list[0]; list.forEach(function (b) { b.setAttribute("tabindex", b === cur ? "0" : "-1"); }); };
    group.addEventListener("keydown", function (e) {
      var list = tabs(), i = list.indexOf(document.activeElement);
      if (i < 0) return;
      var n = e.key === "ArrowRight" ? (i + 1) % list.length : e.key === "ArrowLeft" ? (i - 1 + list.length) % list.length : e.key === "Home" ? 0 : e.key === "End" ? list.length - 1 : -1;
      if (n < 0) return;
      e.preventDefault();
      list[n].focus();
      list[n].click();
      roving();
    });
    group.addEventListener("click", function () { setTimeout(roving, 0); });
    roving();
  }
  // A part that fails to set up (odd markup) does not stop the parts after it.
  function safe(fn, el) { try { fn(el); } catch (e) { if (window.console) console.error("UI kit: a part could not be set up", el, e); } }
  function startKit() {
    toastRegion();
    fillBars(document);
    setupParts(document);
    // Bars and tables a script writes after the page loaded (a dashboard drawn from its data).
    if (window.MutationObserver) {
      new MutationObserver(function (list) {
        list.forEach(function (m) {
          if (m.type === "attributes") { fillBars(m.target); if (/^data-kit-(sort|pages)$/.test(m.attributeName)) setupTables(m.target); }
          else Array.prototype.forEach.call(m.addedNodes, function (n) { if (n.nodeType === 1) { fillBars(n); setupTables(n); setupParts(n); } });
        });
      }).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["aria-valuenow", "aria-valuemin", "aria-valuemax", "data-kit-sort", "data-kit-pages"] });
    }
    setupTables(document);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startKit); else startKit();
})();
