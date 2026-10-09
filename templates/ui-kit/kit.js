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

  // Hold to confirm: <button class="kit-btn kit-btn--hold" data-kit-hold="1500">Delete</button>
  // Fires "kit:hold" on the button when held long enough (mouse, touch, Space or Enter).
  function setupHold(btn) {
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
    var input = box.querySelector("input");
    var list = box.querySelector(".kit-search__list");
    if (!input || !list) return;
    var items = Array.prototype.slice.call(list.querySelectorAll(".kit-search__item"));
    var active = -1;
    function visible() { return items.filter(function (i) { return !i.hidden; }); }
    function mark(n) {
      var v = visible();
      items.forEach(function (i) { i.classList.remove("is-active"); });
      active = v.length ? (n + v.length) % v.length : -1;
      if (active >= 0) v[active].classList.add("is-active");
    }
    function pick(item) {
      if (!item) return;
      input.value = item.getAttribute("data-value") || item.textContent.trim();
      list.hidden = true;
      box.dispatchEvent(new CustomEvent("kit:pick", { bubbles: true, detail: { text: input.value } }));
    }
    function filter() {
      var q = input.value.trim().toLowerCase();
      items.forEach(function (i) { i.hidden = q !== "" && i.textContent.toLowerCase().indexOf(q) < 0; });
      list.hidden = visible().length === 0;
      mark(-1);
    }
    input.addEventListener("input", filter);
    input.addEventListener("focus", filter);
    input.addEventListener("blur", function () { setTimeout(function () { list.hidden = true; }, 120); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown") { e.preventDefault(); mark(active + 1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); mark(active - 1); }
      else if (e.key === "Enter" && active >= 0) { e.preventDefault(); pick(visible()[active]); }
      else if (e.key === "Escape") { list.hidden = true; }
    });
    items.forEach(function (i) { i.addEventListener("mousedown", function (e) { e.preventDefault(); pick(i); }); });
    list.hidden = true;
  }

  // File drop zone: <label class="kit-drop" data-kit-drop><input type="file" multiple> ...</label>
  // Highlights while a file is over it and lists the chosen files. Fires "kit:files" with { files }.
  function setupDrop(zone) {
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
        group.dispatchEvent(new CustomEvent("kit:select", { bubbles: true, detail: { text: b.textContent.trim(), index: buttons.indexOf(b) } }));
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
    var body = table.tBodies[0], headRow = table.tHead && table.tHead.rows[0];
    if (!body) return;
    var external = table.getAttribute("data-kit-rows") === "external";
    var size = parseInt(table.getAttribute("data-kit-pages"), 10) || 0;
    var heads = headRow ? Array.prototype.slice.call(headRow.cells) : [];
    var col = -1, asc = true, page = 0, pager = null, info = null, prev = null, next = null, obs = null;
    function rows() { return Array.prototype.filter.call(body.rows, function (r) { return !r.hasAttribute("data-kit-empty"); }); }
    function value(row, i) {
      var c = row.cells[i];
      if (!c) return "";
      var v = c.getAttribute("data-sort");
      return v === null ? c.textContent.trim() : v;
    }
    function compare(a, b) {
      var x = value(a, col), y = value(b, col), c;
      if (heads[col] && heads[col].classList.contains("kit-num")) c = (Number(String(x).replace(/[^\d.eE-]/g, "")) || 0) - (Number(String(y).replace(/[^\d.eE-]/g, "")) || 0);
      else c = String(x).localeCompare(String(y), undefined, { numeric: true, sensitivity: "base" });
      return asc ? c : -c;
    }
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
      var list = rows();
      if (col >= 0) list.sort(compare).forEach(function (r) { body.appendChild(r); });
      var pages = size ? Math.max(1, Math.ceil(list.length / size)) : 1;
      page = Math.max(0, Math.min(page, pages - 1));
      list.forEach(function (r, i) { r.hidden = !!size && (i < page * size || i >= (page + 1) * size); });
      if (pager) {
        pager.hidden = pages < 2;
        info.textContent = "Page " + (page + 1) + " of " + pages + ", " + list.length + " rows";
        prev.disabled = page === 0;
        next.disabled = page >= pages - 1;
      }
      if (obs) obs.takeRecords();   // our own moves are not a new set of rows
      return pages;
    }
    if (table.hasAttribute("data-kit-sort")) {
      heads.forEach(function (th, i) {
        if (th.hasAttribute("data-kit-nosort")) return;
        var b = document.createElement("button");
        b.type = "button";
        b.className = "kit-table__sort";
        while (th.firstChild) b.appendChild(th.firstChild);
        th.appendChild(b);
        th.setAttribute("aria-sort", "none");
        b.addEventListener("click", function () {
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
    if (window.MutationObserver && external) new MutationObserver(function () { apply(); }).observe(table, { attributes: true, attributeFilter: ["data-kit-total", "data-kit-page"] });
    else if (window.MutationObserver) {
      obs = new MutationObserver(function () { page = 0; apply(); });
      obs.observe(body, { childList: true });
    }
    apply();
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

  function startKit() {
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-hold]"), setupHold);
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-search]"), setupSearch);
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-drop]"), setupDrop);
    Array.prototype.forEach.call(document.querySelectorAll("table[data-kit-sort], table[data-kit-pages]"), setupTable);
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-theme]"), setupTheme);
    Array.prototype.forEach.call(document.querySelectorAll(".kit-tabs--animated"), function (g) { setupSlider(g, ".kit-tab", "aria-selected", "kit-tabs__indicator"); });
    Array.prototype.forEach.call(document.querySelectorAll(".kit-segmented--animated"), function (g) { setupSlider(g, "button", "aria-pressed", "kit-segmented__indicator"); });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startKit); else startKit();
})();
