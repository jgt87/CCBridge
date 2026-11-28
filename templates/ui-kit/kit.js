/*
  UI kit behaviour for plain pages (no build step, works from file://). Load after the page's
  markup: <script src="styles/kit/kit.js"></script>. Each part starts on its data-kit-* attribute
  and reports through a DOM event, so page code listens instead of editing this file.
  Behaviour adapted from an open-source component library (MIT licence; see
  LICENSE-kokonutui.txt): the hold button, search with suggestions, file drop zone and animated tabs.
  The sortable table with pages (data-kit-sort, data-kit-pages, data-kit-rows="external") and the
  theme switch (data-kit-theme) are the kit's own.

  One file on purpose (about 220 KB, 2026-11-24): a plain page loads the kit with one script tag that
  works from file://, with no loader and no order between files to get wrong; the forms parts
  (listbox, number field, typed fields, ...) stay here rather than in a kit-forms.js of their own.

  Deliberate differences from the shared element specs (kept as they are; a later pass may align them):
  avatar 44px; board columns 220px with no phone layout; calendar days at 12px with no agenda view;
  toast radius and stack limit; tooltip padding; chip text 14px; drawer 440px; tree indent 24px; the
  spinner is CSS; command palette width; menu with no max height; confirm about 520px wide without a
  solid danger fill; slider track; tab bold-width reserve; chart markers and value labels; multiselect
  row height; popover clamp, flip and portal; search box icon and clear button; date range trigger.
*/
(function () {
  "use strict";

  // The focus ring is for keyboard navigation (docs/17 section 8): the last input is recorded on
  // <html data-modality>, "keyboard" after a navigation key, "pointer" after a press and at the start,
  // and kit.css hides the ring while it is "pointer". A browser's :focus-visible alone shows it after
  // a click and Shift, and for a focus set at load.
  (function () {
    var root = document.documentElement, NAV = ["Tab", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "F6"];
    var set = function (v) { if (root.getAttribute("data-modality") !== v) root.setAttribute("data-modality", v); };
    set("pointer");
    document.addEventListener("keydown", function (e) { if (NAV.indexOf(e.key) >= 0 && !e.altKey && !e.metaKey && !(e.ctrlKey && e.key === "Tab")) set("keyboard"); }, true);
    ["pointerdown", "mousedown", "touchstart"].forEach(function (t) { document.addEventListener(t, function () { set("pointer"); }, { capture: true, passive: true }); });
  })();
  if (window.KitUI) return;   // loaded twice (head and tail of the page): once is enough

  // Short announcements for screen readers (a tag added, a card moved, a search's result count): one
  // polite live region, made the first time it is needed; text in it is read, not shown. Its look is
  // set here too, so a page whose kit.css lacks kit-sr-only still shows nothing.
  var SR_ONLY = "position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0";
  var liveRegion = null, liveTimer = null;
  function srOnly(el) { el.className = "kit-sr-only"; el.style.cssText = SR_ONLY; return el; }
  function announce(text) {
    if (!document.body) return;
    if (!liveRegion || !liveRegion.parentNode) {
      liveRegion = srOnly(document.createElement("div"));
      liveRegion.setAttribute("aria-live", "polite");
      liveRegion.setAttribute("aria-atomic", "true");
      document.body.appendChild(liveRegion);
    }
    liveRegion.textContent = "";
    clearTimeout(liveTimer);
    liveTimer = setTimeout(function () { liveRegion.textContent = String(text); }, 120);   // a new text after a pause is read even when it repeats
  }
  // Escape that closed a kit part stops there: a dialog or side panel around it stays open.
  function escapeHandled(e) { e.preventDefault(); e.stopPropagation(); }

  // Disabled controls stay focusable (shared element specs, docs/19 section 7): aria-disabled="true" on
  // a control or on a group around it keeps its Tab stop and its place in arrow-key order, and keeps
  // focus when it turns disabled while focused (Save that becomes Saving). aria-disabled stops nothing
  // by itself, so this guard blocks every change first (capture phase on the document): click, Enter,
  // Space, the value keys of native inputs, typing, paste, cut, drop, drag and wheel. A busy button or
  // switch (aria-busy="true") counts as disabled too. A disabled field leaves the form data. Native
  // `disabled` keeps working as before; Tab, Escape and pointer-down (closing a menu) still pass.
  var BUSY_CONTROL = 'button, [role="button"], [role="switch"]';
  var VALUE_INPUT = /^(range|number|date|time|datetime-local|month|week|color)$/;
  var VALUE_KEYS = { ArrowUp: 1, ArrowDown: 1, ArrowLeft: 1, ArrowRight: 1, Home: 1, End: 1, PageUp: 1, PageDown: 1 };
  function nodeElement(node) { return (node && node.nodeType === 1 ? node : node && node.parentElement) || null; }
  function offControl(node) {
    var el = nodeElement(node);
    if (!el || !el.closest) return null;
    var off = el.closest('[aria-disabled="true"]');
    if (off) return off;
    var busy = el.closest(BUSY_CONTROL);
    return busy && busy.getAttribute("aria-busy") === "true" ? busy : null;
  }
  function isOff(el) { return !!el && (el.disabled === true || !!offControl(el)); }
  function guardStop(e) { e.preventDefault(); e.stopImmediatePropagation(); }
  function isValueInput(el) { return el.localName === "input" && VALUE_INPUT.test(el.type || ""); }
  function guardKey(e) {
    if (!offControl(e.target)) return;
    var k = e.key, el = e.target;
    var block = k === "Enter" || k === " " || k === "Spacebar" ||
      (el.localName === "select" && (VALUE_KEYS[k] === 1 || (k.length === 1 && !e.ctrlKey && !e.metaKey))) ||
      (isValueInput(el) && VALUE_KEYS[k] === 1);
    if (block) guardStop(e);
  }
  function guardEdit(e) { if (offControl(e.target)) guardStop(e); }
  function guardPress(e) {   // a native select or range acts on press (the picker, a drag): keep focus only
    var el = nodeElement(e.target);
    if (!el || !(el.localName === "select" || isValueInput(el)) || !offControl(el)) return;
    e.preventDefault();
    if (el.focus) el.focus();
  }
  function guardDropData(e) {   // a disabled field sends no value, as native disabled would
    var form = e.target, data = e.formData;
    if (!data || !form || !form.elements) return;
    Array.prototype.forEach.call(form.elements, function (f) { if (f.name && (offControl(f) || (f.kitFor && isOff(f.kitFor)))) data.delete(f.name); });   // a hidden value of a disabled part too
  }
  function setupGuard() {
    var cap = { capture: true };
    ["click", "auxclick", "dblclick", "beforeinput", "paste", "cut", "drop", "dragstart"].forEach(function (t) { document.addEventListener(t, guardEdit, cap); });
    document.addEventListener("keydown", guardKey, cap);
    document.addEventListener("mousedown", guardPress, cap);
    document.addEventListener("wheel", function (e) { var el = nodeElement(e.target); if (el && (el.localName === "select" || isValueInput(el)) && offControl(el)) e.preventDefault(); }, { capture: true, passive: false });
    document.addEventListener("formdata", guardDropData, cap);
  }

  // Hold to confirm: <button class="kit-btn kit-btn--hold" data-kit-hold="1500">Delete</button>
  // Fires "kit:hold" on the button when held long enough (mouse, touch, Space or Enter).
  function isHoldKey(k) { return k === " " || k === "Enter"; }
  // One hidden description for every hold button (aria-describedby reads hidden text).
  function holdHelp() {
    var help = document.getElementById("kit-hold-help");
    if (!help) {
      help = document.createElement("span");
      help.id = "kit-hold-help";
      help.hidden = true;
      help.textContent = "Press and hold to confirm";
      document.body.appendChild(help);
    }
    return help.id;
  }
  function setupHold(btn) {
    if (btn.kitHold) return;
    btn.kitHold = true;
    var ms = parseInt(btn.getAttribute("data-kit-hold"), 10) || 1500;
    var timer = null;
    btn.style.setProperty("--kit-hold-ms", ms + "ms");
    var described = btn.getAttribute("aria-describedby") || "";
    if (!/(^|\s)kit-hold-help(\s|$)/.test(described)) btn.setAttribute("aria-describedby", (described + " " + holdHelp()).trim());
    function isKey(e) { return !!e && e.type === "keydown"; }
    // data-kit-hold-done="Deleted" on the button: the confirmed word, said and shown in its
    // [data-kit-hold-label] part (the same verb as the label), until the next hold.
    var labelEl = btn.querySelector("[data-kit-hold-label]"), labelText = labelEl ? labelEl.textContent : "";
    function begin(e) {
      if (timer || isOff(btn)) return;
      if (isKey(e) && !isHoldKey(e.key)) return;
      if (isKey(e) && e.repeat) { e.preventDefault(); return; }   // a held key repeats: it does not start again
      if (!isKey(e) && e.button !== 0) return;   // only the primary button holds (not a right or middle press)
      if (isKey(e)) e.preventDefault();   // no native click: the hold is the action
      btn.classList.remove("is-done");
      if (labelEl) labelEl.textContent = labelText;
      btn.classList.add("is-holding");
      timer = setTimeout(function () {
        timer = null;
        btn.classList.remove("is-holding");
        btn.classList.add("is-done");
        var done = btn.getAttribute("data-kit-hold-done");
        if (done && labelEl) labelEl.textContent = done;
        announce(done || ((btn.getAttribute("aria-label") || btn.textContent.trim()) + ": confirmed"));
        btn.dispatchEvent(new CustomEvent("kit:hold", { bubbles: true }));
      }, ms);
    }
    function stop(e) {
      if (e && e.type === "keyup" && isHoldKey(e.key)) e.preventDefault();   // Space's keyup would click
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
    input.addEventListener("input", function () {
      filter();
      var n = visible().length;
      announce(n === 1 ? "1 result" : n + " results");
    });
    input.addEventListener("focus", filter);
    input.addEventListener("blur", function () { setTimeout(function () { open(false); }, 120); });
    input.addEventListener("keydown", function (e) {
      if (e.isComposing) return;   // Enter or Escape that ends an input-method composition
      if (e.key === "ArrowDown") { e.preventDefault(); mark(active + 1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); mark(active - 1); }
      else if (e.key === "Enter" && active >= 0) { e.preventDefault(); pick(visible()[active]); }
      else if (e.key === "Escape" && !list.hidden) { escapeHandled(e); open(false); }
      // A second Escape (the list already closed) clears the text.
      else if (e.key === "Escape" && input.value) { escapeHandled(e); input.value = ""; items.forEach(function (i) { i.hidden = false; }); mark(-1); }
    });
    items.forEach(function (i) { i.addEventListener("mousedown", function (e) { e.preventDefault(); pick(i); }); });
    open(false);
  }

  // A chosen file's row: the name truncates in the middle, so the stem shrinks with an ellipsis and
  // the extension keeps its width (".env" or a name without a dot is all stem). Text nodes only, so
  // a file name never becomes markup; the full name is the row's title.
  function dropFileRow(name) {
    var li = document.createElement("li");
    var at = name.lastIndexOf(".");
    var stem = document.createElement("span");
    li.className = "kit-drop__file";
    li.title = name;
    stem.className = "kit-drop__stem";
    stem.textContent = at > 0 ? name.slice(0, at) : name;
    li.appendChild(stem);
    if (at > 0) {
      var ext = document.createElement("span");
      ext.className = "kit-drop__ext";
      ext.textContent = name.slice(at);
      li.appendChild(ext);
    }
    return li;
  }

  // True when a file matches an input's accept list (".csv,image/*,application/pdf"); no list takes every file.
  function dropAccepts(file, accept) {
    var parts = String(accept || "").split(",").map(function (p) { return p.trim().toLowerCase(); }).filter(Boolean);
    if (!parts.length) return true;
    var name = String(file.name || "").toLowerCase();
    var type = String(file.type || "").toLowerCase();
    return parts.some(function (p) {
      if (p.charAt(0) === ".") return name.slice(-p.length) === p;
      if (p.slice(-2) === "/*") return type.indexOf(p.slice(0, -1)) === 0;
      return type === p;
    });
  }
  // Says which dropped files were not taken (role="alert"), or removes the note.
  function dropRefused(zone, text) {
    var note = zone.querySelector(".kit-drop__refused");
    if (!text) { if (note) note.parentNode.removeChild(note); return; }
    if (!note) { note = document.createElement("span"); note.className = "kit-error-text kit-drop__refused"; note.setAttribute("role", "alert"); zone.appendChild(note); }
    note.textContent = text;
  }

  // File drop zone: <label class="kit-drop" data-kit-drop><input type="file" multiple> ...</label>
  // Highlights while a file is over it and lists the chosen files. Fires "kit:files" with { files }.
  function setupDrop(zone) {
    if (zone.kitDrop) return;
    zone.kitDrop = true;
    var input = zone.querySelector('input[type="file"]');
    var out = zone.querySelector(".kit-drop__files");
    function show(files) {
      if (out) { out.textContent = ""; Array.prototype.forEach.call(files, function (f) { out.appendChild(dropFileRow(f.name)); }); }
      zone.dispatchEvent(new CustomEvent("kit:files", { bubbles: true, detail: { files: files } }));
    }
    // dragenter/dragleave also fire over the zone's own children: count them so the highlight does not flicker.
    var depth = 0;
    zone.addEventListener("dragenter", function (e) { e.preventDefault(); depth++; zone.classList.add("is-over"); });
    zone.addEventListener("dragover", function (e) { e.preventDefault(); zone.classList.add("is-over"); });
    zone.addEventListener("dragleave", function () { depth = Math.max(0, depth - 1); if (!depth) zone.classList.remove("is-over"); });
    // The picker filters by accept and multiple itself; a drop does not, so check it here.
    zone.addEventListener("drop", function (e) {
      e.preventDefault();
      depth = 0;
      zone.classList.remove("is-over");
      if (!e.dataTransfer || !e.dataTransfer.files.length) return;
      var all = e.dataTransfer.files;
      var accept = input ? input.getAttribute("accept") : "";
      var ok = Array.prototype.filter.call(all, function (f) { return dropAccepts(f, accept); });
      if (input && !input.multiple) ok = ok.slice(0, 1);
      var wrong = Array.prototype.filter.call(all, function (f) { return !dropAccepts(f, accept); });
      dropRefused(zone, wrong.length ? "Not taken (" + accept + " only): " + wrong.map(function (f) { return f.name; }).join(", ") : "");
      if (ok.length) show(ok.length === all.length ? all : ok);
    });
    if (input) input.addEventListener("change", function () { dropRefused(zone, ""); if (input.files.length) show(input.files); });
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
    var scaled = indicatorClass === "kit-tabs__indicator";   // kit.css: 100px wide, scaled to the tab
    function move() {
      var cur = buttons.filter(function (b) { return b.getAttribute(attr) === "true"; })[0];
      if (scaled) { ind.style.transform = cur ? "translateX(" + cur.offsetLeft + "px) scaleX(" + cur.offsetWidth / 100 + ")" : "scaleX(0)"; return; }
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

  // Sortable table with pages (the kit's own part, not adapted):
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
  // What a cell sorts by: its data-sort, else its text.
  function cellSortValue(row, i) {
    var c = row.cells[i];
    if (!c) return "";
    var v = c.getAttribute("data-sort");
    return v === null ? c.textContent.trim() : v;
  }
  // Numbers as people write them (kit-num columns): "1,234.56", "1.234,56", "41,7%", "(1,234)",
  // "5.210". The column decides its decimal separator: a value with 1, 2 or 4+ digits after a
  // separator makes that one the decimal; dots only in groups of three are thousands.
  function columnSeparators(values) {
    var comma = false, dot = false, dotGroups = true;
    values.forEach(function (raw) {
      var v = raw.replace(/[^\d.,]/g, "");
      if (/,\d{3}\./.test(v) || /\.\d{1,2}$/.test(v) || /\.\d{4,}$/.test(v)) dot = true;
      if (/\.\d{3},/.test(v) || /,\d{1,2}$/.test(v) || /,\d{4,}$/.test(v)) comma = true;
      if (v.indexOf(".") >= 0 && !/^\d{1,3}(\.\d{3})+$/.test(v.replace(/,.*$/, ""))) dotGroups = false;
    });
    // groups: every dot in the column groups thousands ("5.210")
    return { sep: comma && !dot ? "," : ".", groups: dotGroups && !dot };
  }
  // The digits of a number as parseFloat reads them, by the column's separators.
  function plainDigits(v, seps) {
    if (seps.sep === ",") return v.replace(/\./g, "").replace(",", ".");
    v = v.replace(/,/g, "");
    return seps.groups && /^\d{1,3}(\.\d{3})+$/.test(v) ? v.replace(/\./g, "") : v;
  }
  // Ascending order of two sort keys; what is not a number (empty, "n/a") sorts last, whichever way.
  function compareKeys(x, y, asc) {
    if (typeof x === "number" || typeof y === "number") return compareNumbers(x, y, asc);
    var c = String(x).localeCompare(String(y), undefined, { numeric: true, sensitivity: "base" });
    return asc ? c : -c;
  }
  // Two number keys; one that is not a number (NaN, a word) goes last in both directions.
  function compareNumbers(x, y, asc) {
    var nx = typeof x === "number" && !isNaN(x), ny = typeof y === "number" && !isNaN(y);
    if (nx && ny) return asc ? x - y : y - x;
    return nx === ny ? 0 : (nx ? -1 : 1);
  }
  function hasWords(row, words) { var t = row.textContent.toLowerCase(); return words.every(function (x) { return t.indexOf(x) >= 0; }); }
  // A header cell's sort button (none for data-kit-nosort or a cell that has one).
  function armHead(th, onSort) {
    if (th.hasAttribute("data-kit-nosort") || th.querySelector(".kit-table__sort")) return;
    var b = document.createElement("button");
    b.type = "button";
    b.className = "kit-table__sort";
    while (th.firstChild) b.appendChild(th.firstChild);
    th.appendChild(b);
    th.setAttribute("aria-sort", "none");
    b.addEventListener("click", function () { onSort(th); });
  }
  // The pager after the table (or its kit-table-wrap); go(-1) and go(1) on Previous and Next.
  function makePager(table, go) {
    var pager = document.createElement("div");
    pager.className = "kit-pager";
    pager.innerHTML = '<button class="kit-btn kit-btn--sm" type="button">Previous</button><span class="kit-pager__info" aria-live="polite"></span><button class="kit-btn kit-btn--sm" type="button">Next</button>';
    var prev = pager.firstChild, info = prev.nextSibling, next = info.nextSibling;
    var wrap = table.closest(".kit-table-wrap") || table;
    wrap.parentNode.insertBefore(pager, wrap.nextSibling);
    prev.addEventListener("click", function () { go(-1); });
    next.addEventListener("click", function () { go(1); });
    return { pager: pager, prev: prev, info: info, next: next };
  }
  // Row selection (data-kit-select): a checkbox column, "select all" in the header, picked rows
  // marked aria-selected, a kit-bulk bar (data-kit-bulk="TABLE-ID") with the count and the actions,
  // and "kit:selection" with detail.ids (the rows' data-id), rows and count. rows() and bodyOf()
  // give the table's rows and body now; arm() puts the sort buttons in their places again.
  function setupRowSelect(table, rows, bodyOf, arm) {
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
      var body = bodyOf();
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
  // What a set of DOM changes touched: the header row, the rows, or (external) the table's attributes.
  function tableChanges(table, list) {
    var c = { head: false, rows: false, attrs: false };
    list.forEach(function (m) {
      if (m.type === "attributes") c.attrs = true;
      else if (table.tHead && table.tHead.contains(m.target)) c.head = true;
      else c.rows = true;
    });
    return c;
  }
  // A number as people write it ("(1.234,5)", "-12 %"), with the column's separators; NaN when none.
  function parseSortNumber(s, sep) {
    var raw = String(s).trim();
    if (!raw) return NaN;
    var neg = /^\(.*\)$/.test(raw) || /^[^\d]*-/.test(raw);
    var v = raw.replace(/[^\d.,]/g, "");
    if (!v) return NaN;
    var n = parseFloat(plainDigits(v, sep));
    return isNaN(n) ? NaN : (neg ? -n : n);
  }
  // Watches the table's rows (and, external, its data-kit-total and data-kit-page); null without MutationObserver.
  function observeTable(table, external, onChange) {
    if (!window.MutationObserver) return null;
    var obs = new MutationObserver(onChange);
    obs.observe(table, external ? { childList: true, subtree: true, attributes: true, attributeFilter: ["data-kit-total", "data-kit-page"] } : { childList: true, subtree: true });
    return obs;
  }
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
    // A column's separators, read from its rows the first time a number in it is needed.
    function separators(i) { return numSep[i] || (numSep[i] = columnSeparators(rows().map(function (r) { return cellSortValue(r, i); }))); }
    function toNumber(s, i) { return parseSortNumber(s, separators(i)); }
    function sortKey(row) {
      var k = row.__kitKeys || (row.__kitKeys = {});
      if (k[col] === undefined) k[col] = heads[col] && heads[col].classList.contains("kit-num") ? toNumber(cellSortValue(row, col), col) : cellSortValue(row, col);
      return k[col];
    }
    function compare(a, b) { return compareKeys(sortKey(a), sortKey(b), asc); }
    function forgetKeys() { numSep = {}; sortedCol = -1; rows().forEach(function (r) { r.__kitKeys = null; }); }
    function slice(pages) {
      return { page: page + 1, pages: pages, start: page * size, end: size ? (page + 1) * size : Infinity };
    }
    function pageCount(n) { return size ? Math.max(1, Math.ceil(n / size)) : 1; }
    function clampPage(pages) { page = Math.max(0, Math.min(page, pages - 1)); }
    // The pager under the table (when there is one): "Page 2 of 5, 120 rows", Previous and Next.
    function showPager(pages, count) {
      if (!pager) return;
      pager.hidden = pages < 2;
      info.textContent = "Page " + (page + 1) + " of " + pages + ", " + count + " rows";
      prev.disabled = page === 0;
      next.disabled = page >= pages - 1;
    }
    // External rows are the page's own: only the pager follows data-kit-total and data-kit-page.
    function applyExternal() {
      var total = Math.max(0, parseInt(table.getAttribute("data-kit-total"), 10) || 0);
      var want = parseInt(table.getAttribute("data-kit-page"), 10);
      var xpages = pageCount(total);
      if (want > 0) page = want - 1;
      clampPage(xpages);
      showPager(xpages, total.toLocaleString());
      return xpages;
    }
    // Rows are moved only when the order asked for changed since they were last put in order.
    function orderChanged() { return col !== sortedCol || asc !== sortedAsc; }
    function sortRows(all) {
      if (col < 0) return;
      if (body && orderChanged()) {
        all.sort(compare).forEach(function (r) { body.appendChild(r); });
        sortedCol = col; sortedAsc = asc;
      } else all.sort(compare);
    }
    function searchWords() { return query.toLowerCase().split(/\s+/).filter(Boolean); }
    // The search box (data-kit-filter): rows without the words are hidden, paging counts the rest.
    function matching(all, words) { return all.filter(function (r) { var hit = hasWords(r, words); if (!hit) r.hidden = true; return hit; }); }
    // No rows left (a search with no match, or no data yet): the empty row shows, the totals row hides.
    function showEmpty(count) {
      var emptyRow = body && body.querySelector("tr[data-kit-empty]");
      if (emptyRow) emptyRow.hidden = count > 0;
      if (table.tFoot && table.tFoot.classList.contains("kit-table__total")) table.tFoot.hidden = count === 0;
    }
    function apply() {
      if (external) return applyExternal();
      var all = rows();
      sortRows(all);
      var words = searchWords();
      var list = matching(all, words);
      matched = list.length;
      var pages = pageCount(list.length);
      clampPage(pages);
      list.forEach(function (r, i) { r.hidden = !!size && (i < page * size || i >= (page + 1) * size); });
      showEmpty(list.length);
      showPager(pages, list.length + (words.length ? " of " + all.length : ""));
      if (obs) obs.takeRecords();   // our own moves are not a new set of rows
      return pages;
    }
    // On paper every matching row shows (kit.js calls this around printing).
    table.kitPrint = function (on) {
      if (external || !size) return;
      if (on) { var words = searchWords(); rows().forEach(function (r) { r.hidden = !hasWords(r, words); }); }
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
    // A header's sort button: sorts by that column, the other way round when it already was.
    function sortBy(th) {
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
    }
    // Sort buttons in the header cells that have none yet (also cells written later).
    function arm() {
      var headRow = table.tHead && table.tHead.rows[0];
      heads = headRow ? Array.prototype.slice.call(headRow.cells) : [];
      if (!table.hasAttribute("data-kit-sort")) return;
      heads.forEach(function (th) { armHead(th, sortBy); });
    }
    function go(d) {
      page += d;
      if (external) table.setAttribute("data-kit-page", String(page + 1));
      var pages = apply();
      table.dispatchEvent(new CustomEvent("kit:page", { bubbles: true, detail: slice(pages) }));
    }
    // Rows written again are sorted and paged again (the page's own rows in external mode); a
    // header row written again gets its sort buttons; a body put in later is the one used.
    function onChange(list) {
      var c = tableChanges(table, list);
      if (table.tBodies[0] !== body) body = table.tBodies[0];
      if (c.rows) forgetKeys();
      if (c.head || c.rows) arm();
      if (c.rows && table.kitArmSelect) table.kitArmSelect();
      reapply(c);
      obs.takeRecords();
    }
    // External mode: the page's rows again on any change; else new rows start again at the first page.
    function reapply(c) {
      if (external) { if (c.attrs || c.rows) apply(); }
      else if (c.rows) { page = 0; apply(); }
    }
    arm();
    if (table.hasAttribute("data-kit-select")) setupRowSelect(table, rows, function () { return body; }, arm);
    if (size) { var parts = makePager(table, go); pager = parts.pager; prev = parts.prev; info = parts.info; next = parts.next; }
    obs = observeTable(table, external, onChange);
    apply();
    if (obs) obs.takeRecords();
  }

  // Light and dark: <button class="kit-btn kit-btn--ghost kit-btn--icon" type="button" data-kit-theme>
  // <span data-kit-icon="moon" aria-hidden="true"></span></button>. Follows the computer's setting
  // until clicked; the choice is kept in this browser (when it may keep it) and set as data-theme
  // on <html>, which tokens.css follows. Its icon shows what a click switches to (moon, sun), its
  // label says so too. Fires "kit:theme" { theme: "light" | "dark" } on the button.
  var THEME_KEY = "kit-theme";
  function readTheme() { try { return localStorage.getItem(THEME_KEY); } catch (e) { return null; } }   // blocked storage: follow the computer
  function isDark() {
    var t = document.documentElement.getAttribute("data-theme");
    if (t === "dark" || t === "light") return t === "dark";
    return !!(window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches);
  }
  var saved = readTheme();
  if (saved === "dark" || saved === "light") document.documentElement.setAttribute("data-theme", saved);
  // The computer switching between light and dark (while no choice is on <html>) is a theme change too:
  // one "kit:theme" on the document, so charts and canvas code read their colours again.
  if (window.matchMedia && !window.kitSystemThemeEvent) {
    window.kitSystemThemeEvent = true;
    var sysMq = matchMedia("(prefers-color-scheme: dark)");
    if (sysMq.addEventListener) sysMq.addEventListener("change", function () {
      var t = document.documentElement.getAttribute("data-theme");
      if (t === "dark" || t === "light") return;
      document.dispatchEvent(new CustomEvent("kit:theme", { detail: { theme: isDark() ? "dark" : "light" } }));
    });
  }
  function setupTheme(btn) {
    if (btn.kitTheme) return;
    btn.kitTheme = true;
    function showTheme() {
      var dark = isDark(), icon = btn.querySelector("[data-kit-icon]");
      if (icon) icon.setAttribute("data-kit-icon", dark ? "sun" : "moon");
      btn.setAttribute("aria-label", dark ? "Switch to the light theme" : "Switch to the dark theme");
      btn.removeAttribute("title");
      btn.setAttribute("data-kit-tooltip", btn.getAttribute("aria-label"));   // the kit's tooltip says the same
      if (tooltipFor === btn && tooltip) tooltip.textContent = btn.getAttribute("aria-label");
    }
    btn.kitShowTheme = showTheme;
    btn.addEventListener("click", function () {
      var theme = isDark() ? "light" : "dark", root = document.documentElement;
      // Every surface changes at once: transitions stay off for two frames (kit.css), so no part fades on its own.
      root.setAttribute("data-kit-theme-switching", "");
      root.setAttribute("data-theme", theme);
      var raf = window.requestAnimationFrame || function (f) { return setTimeout(f, 16); };
      raf(function () { raf(function () { root.removeAttribute("data-kit-theme-switching"); }); });
      try { localStorage.setItem(THEME_KEY, theme); } catch (e) { /* not kept: private window or blocked storage */ }
      // Every theme button on the page says what a click does now, not only the one pressed.
      Array.prototype.forEach.call(document.querySelectorAll("[data-kit-theme]"), function (b) { if (b.kitShowTheme) b.kitShowTheme(); });
      btn.dispatchEvent(new CustomEvent("kit:theme", { bubbles: true, detail: { theme: theme } }));
    });
    if (window.matchMedia) {
      var mq = matchMedia("(prefers-color-scheme: dark)");
      if (mq.addEventListener) mq.addEventListener("change", showTheme);
    }
    showTheme();
  }

  // A kit-progress bar shows its value: aria-valuenow (or data-value; with aria-valuemin /
  // aria-valuemax, else 0..100) sets the width of its kit-progress__bar, also for bars written or
  // changed later. A bar without a value takes the percentage shown in its own cell, then the cell
  // next to it, then its row (a table with a % column next to its bars), unless the page set the
  // width itself. A value written as a fraction (0.42) while the row shows 42% fills to 42%. A bar
  // with no value and no percentage near it stays a progress with no known end (kit.css).
  var PERCENT = /(-?\d+(?:[.,]\d+)?)\s*%/g;
  function percentsIn(el, track) {
    if (!el) return [];
    var text = el.textContent || "";
    var own = track.textContent || "";
    if (own && el.contains(track)) text = text.replace(own, " ");
    var out = [], m;
    PERCENT.lastIndex = 0;
    while ((m = PERCENT.exec(text))) out.push(parseFloat(m[1].replace(",", ".")));
    return out;
  }
  function shownPercent(track) {
    var cell = track.closest("td, th");
    var inCell = percentsIn(cell || track.parentElement, track);
    if (inCell.length) return inCell[0];
    if (cell) {
      var near = percentsIn(cell.nextElementSibling, track).concat(percentsIn(cell.previousElementSibling, track));
      if (near.length) return near[0];
    }
    var inRow = percentsIn(track.closest("tr, li"), track);
    return inRow.length === 1 ? inRow[0] : null;
  }
  function fillBar(track) {
    var bar = track.querySelector(".kit-progress__bar");
    if (!bar) return;
    var raw = track.getAttribute("aria-valuenow") || track.getAttribute("data-value");
    var now = raw === null ? NaN : parseFloat(String(raw).replace(",", "."));
    var shown = shownPercent(track);
    var pct;
    if (!isNaN(now)) {
      var min = parseFloat(track.getAttribute("aria-valuemin")); if (isNaN(min)) min = 0;
      var max = parseFloat(track.getAttribute("aria-valuemax")); if (isNaN(max)) max = 100;
      pct = max > min ? (now - min) / (max - min) * 100 : 0;
      if (shown !== null && now > 0 && now <= 1 && max === 100 && Math.abs(now * 100 - shown) < 1) pct = shown;
    } else {
      if (shown === null || (bar.style.width && !bar.hasAttribute("data-kit-filled"))) return; // no value, or the page set the width itself
      pct = shown;
      track.setAttribute("aria-valuenow", String(shown));
    }
    if (!track.hasAttribute("role")) track.setAttribute("role", "progressbar");
    bar.setAttribute("data-kit-filled", "");
    bar.style.width = Math.max(0, Math.min(100, pct)) + "%";
  }
  function fillBars(root) {
    if (root.matches && root.matches(".kit-progress")) fillBar(root);
    if (root.querySelectorAll) Array.prototype.forEach.call(root.querySelectorAll(".kit-progress"), fillBar);
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
  function isKitPanel(el) { return !!el.matches && el.matches("dialog") && (el.classList.contains(DRAWER) || el.classList.contains(DIALOG) || el.hasAttribute("data-kit-sheet")); }
  document.addEventListener("close", function (e) {
    if (isKitPanel(e.target)) e.target.dispatchEvent(new CustomEvent("kit:close", { bubbles: true }));
  }, true);

  // Toasts: KitUI.toast("Saved", { tone: "ok" | "warn" | "error", ms: 4000, close: false,
  // action: { label: "Undo", onClick: fn } }), read out by screen readers. Each has a Dismiss button
  // (close: false leaves it out) and waits while the pointer is on it or the focus is in it. One action
  // at most (a ghost button: Undo, Retry, Open): clicking it runs onClick and closes the toast; a toast
  // with an action stays at least 10 s, so there is time to use it. Errors go into the alert region
  // (read at once), the others into the polite status region; both exist from the start.
  function toastClose(onClick) {
    var x = document.createElement("button");
    x.type = "button";
    x.className = "kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm kit-toast__close";
    x.setAttribute("aria-label", "Dismiss");
    if (window.KitIcons) { var ic = document.createElement("span"); ic.setAttribute("data-kit-icon", "x"); ic.setAttribute("aria-hidden", "true"); x.appendChild(ic); }   // the icons script draws it
    else x.textContent = "\u00d7";
    x.addEventListener("click", onClick);
    return x;
  }
  // The toast itself: its tone as a class and, for screen readers, as its first word.
  function toastBox(text, tone) {
    var t = document.createElement("div");
    t.className = "kit-toast" + (/^(ok|warn|error)$/.test(tone || "") ? " kit-toast--" + tone : "");
    t.textContent = String(text);
    var word = { error: "Error: ", warn: "Warning: " }[tone];
    if (word) { var w = srOnly(document.createElement("span")); w.textContent = word; t.insertBefore(w, t.firstChild); }
    return t;
  }
  // How long a toast stays: opts.ms, else 8 s for an error and 4 s for the rest; with an action at least 10 s.
  function toastMs(opts, action) {
    var ms = opts.ms || (opts.tone === "error" ? 8000 : 4000);
    return action ? Math.max(ms, 10000) : ms;
  }
  function toastAction(action, leave) {
    var a = document.createElement("button");
    a.type = "button";
    a.className = "kit-btn kit-btn--ghost kit-btn--sm kit-toast__action";
    a.textContent = String(action.label);
    a.addEventListener("click", function () { leave(); if (typeof action.onClick === "function") action.onClick(); });
    return a;
  }
  function toast(text, opts) {
    opts = opts || {};
    var region = toastRegion();
    if (opts.tone === "error") region = toastAlerts(region);
    var t = toastBox(text, opts.tone);
    var action = opts.action && opts.action.label ? opts.action : null;
    var left = toastMs(opts, action), timer = null, since = 0, over = false;
    var leave = function () {
      clearTimeout(timer); timer = null;
      if (t.classList.contains("is-leaving")) return;
      t.classList.add("is-leaving");
      if (t.contains(document.activeElement)) { focusBack(toastBack, null); toastBack = null; }   // reached by F6
      setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); if (typeof opts.onClose === "function") safe(opts.onClose); }, 400);   // onClose: gone, after its action ran
    };
    var run = function () { if (timer || t.classList.contains("is-leaving")) return; since = Date.now(); timer = setTimeout(leave, left); };
    var pause = function () { if (!timer) return; clearTimeout(timer); timer = null; left = Math.max(1000, left - (Date.now() - since)); };
    if (action) t.appendChild(toastAction(action, leave));
    if (opts.close !== false) t.appendChild(toastClose(leave));
    t.addEventListener("mouseenter", function () { over = true; pause(); });
    t.addEventListener("mouseleave", function () { over = false; if (!t.contains(document.activeElement)) run(); });
    t.addEventListener("focusin", pause);
    t.addEventListener("focusout", function (e) { if (!over && !withinEl(t, e)) run(); });
    region.appendChild(t);
    run();
    return t;
  }

  // Info tip: <button class="kit-tip" type="button" aria-label="How it is counted" data-kit-tip="TEXT">.
  var tipCount = 0, tipWarmUntil = 0, TIP_DELAY = 500, TIP_WARM = 600;
  function hideTips(except) {
    Array.prototype.forEach.call(document.querySelectorAll(".kit-tip__bubble:not([hidden])"), function (b) {
      if (except && except.contains(b)) return;
      if (b.kitHide) b.kitHide(); else b.hidden = true;
    });
  }
  window.addEventListener("scroll", function () { hideTips(); }, true);
  window.addEventListener("wheel", function () { hideTips(); }, { passive: true });
  document.addEventListener("pointerdown", function (e) { hideTips(e.target && e.target.closest ? e.target.closest(".kit-tip, [data-kit-tip]") : null); }, true);
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
    var wait = null;
    var show = function () {
      clearTimeout(wait); wait = null;
      bubble.textContent = btn.getAttribute("data-kit-tip"); bubble.hidden = false;
      bubble.classList.remove("is-left", "is-right", "is-below");
      var r = bubble.getBoundingClientRect();
      if (r.left < 8) bubble.classList.add("is-left"); else if (r.right > window.innerWidth - 8) bubble.classList.add("is-right");
      if (r.top < 8) bubble.classList.add("is-below");
    };
    var hide = function () {
      clearTimeout(wait); wait = null;
      if (!bubble.hidden) tipWarmUntil = Date.now() + TIP_WARM;
      bubble.hidden = true;
    };
    bubble.kitHide = hide;
    btn.addEventListener("mouseenter", function () {
      if (!bubble.hidden || wait) return;
      if (Date.now() < tipWarmUntil) show(); else wait = setTimeout(show, TIP_DELAY);
    });
    btn.addEventListener("focus", show);
    btn.addEventListener("mouseleave", function () { if (document.activeElement !== btn) hide(); });
    btn.addEventListener("blur", hide);
    btn.addEventListener("keydown", function (e) { if (e.key === "Escape" && !bubble.hidden) { escapeHandled(e); hide(); } });
    btn.addEventListener("click", function (e) { e.preventDefault(); if (bubble.hidden) show(); else hide(); });
  }

  // Tooltip: data-kit-tooltip="TEXT" on any element (an icon button, a cut-off text) instead of title. One
  // bubble for the page (kit-tooltip, role="tooltip") with the info tip's look and timing: after the pointer
  // rests on the element, at once on keyboard focus and next to a tip that just closed; above the element,
  // below it when there is no room, kept inside the window; gone on leave, blur, Escape, a press, scroll and
  // wheel; never on touch. It describes the element (aria-describedby), and names one that has no name.
  var tooltip = null, tooltipFor = null, tooltipWait = null, pressAt = 0, touchAt = 0;
  function setupTooltip(el) {
    var title = el.getAttribute("title");
    if (title !== null) {   // a title would show the browser's own tooltip as well
      if (!el.getAttribute("data-kit-tooltip")) el.setAttribute("data-kit-tooltip", title);
      el.removeAttribute("title");
    }
    var text = (el.getAttribute("data-kit-tooltip") || "").trim();
    if (text && !hasName(el)) el.setAttribute("aria-label", text);
  }
  function hasName(el) { return !!(el.getAttribute("aria-label") || el.getAttribute("aria-labelledby") || el.textContent.trim()); }
  function tooltipOf(t) { return t && t.closest ? t.closest("[data-kit-tooltip]") : null; }
  // The pointer or focus moved to a part of el itself (not really in or out of it).
  function withinEl(el, e) { return !!(e.relatedTarget && el.contains(e.relatedTarget)); }
  function tooltipShown() { return !!(tooltipFor && tooltip && !tooltip.hidden); }
  function hideTooltip(warm) {
    clearTimeout(tooltipWait); tooltipWait = null;
    if (!tooltipFor) return;
    if (tooltip && !tooltip.hidden) { tooltip.hidden = true; if (warm !== false) tipWarmUntil = Date.now() + TIP_WARM; }
    if (tooltipFor.getAttribute("aria-describedby") === "kit-tooltip") tooltipFor.removeAttribute("aria-describedby");
    tooltipFor = null;
  }
  function placeTooltip(el) {
    var r = el.getBoundingClientRect(), b = tooltip.getBoundingClientRect(), gap = 6, edge = 8;
    var left = Math.max(edge, Math.min(r.left + r.width / 2 - b.width / 2, window.innerWidth - edge - b.width));
    var top = r.top - gap - b.height;
    if (top < edge) top = r.bottom + gap;
    tooltip.style.left = Math.round(left) + "px";
    tooltip.style.top = Math.round(top) + "px";
  }
  function showTooltip(el) {
    clearTimeout(tooltipWait); tooltipWait = null;
    var text = (el.getAttribute("data-kit-tooltip") || "").trim();
    if (!text || !document.body || !document.body.contains(el)) return;
    if (tooltipFor && tooltipFor !== el) hideTooltip(false);
    tooltipBubble();
    tooltip.textContent = text;
    tooltip.hidden = false;
    tooltipFor = el;
    tooltipDescribes(el, text);
    placeTooltip(el);
  }
  // The page's one bubble, made the first time (and again when the page removed it).
  function tooltipBubble() {
    if (tooltip && tooltip.parentNode) return;
    tooltip = document.createElement("div");
    tooltip.className = "kit-tooltip";
    tooltip.id = "kit-tooltip";
    tooltip.setAttribute("role", "tooltip");
    document.body.appendChild(tooltip);
  }
  // The bubble describes el, unless it only repeats el's name or el is described already.
  function tooltipDescribes(el, text) {
    if (text !== (el.getAttribute("aria-label") || "").trim() && !el.getAttribute("aria-describedby")) el.setAttribute("aria-describedby", tooltip.id);
  }
  function pressed(e) { pressAt = Date.now(); if (e.pointerType === "touch" || e.type === "touchstart") touchAt = pressAt; hideTooltip(); }
  document.addEventListener("pointerdown", pressed, true);
  document.addEventListener("touchstart", pressed, { capture: true, passive: true });
  document.addEventListener("mousedown", function () { pressAt = Date.now(); }, true);
  document.addEventListener("mouseover", function (e) {
    var el = tooltipOf(e.target);
    if (!el || el === tooltipFor || withinEl(el, e)) return;
    if (Date.now() - touchAt < 1000) return;   // the mouse events a tap makes: no hover tooltips on touch
    clearTimeout(tooltipWait);
    if (Date.now() < tipWarmUntil) showTooltip(el); else tooltipWait = setTimeout(function () { showTooltip(el); }, TIP_DELAY);
  });
  document.addEventListener("mouseout", function (e) {
    var el = tooltipOf(e.target);
    if (!el || withinEl(el, e)) return;
    clearTimeout(tooltipWait); tooltipWait = null;
    if (el === tooltipFor && !el.contains(document.activeElement)) hideTooltip();
  });
  document.addEventListener("focusin", function (e) {
    var el = tooltipOf(e.target);
    if (el && Date.now() - pressAt > 600) showTooltip(el);   // keyboard focus, not the focus a click gives
  });
  document.addEventListener("focusout", function (e) {
    var el = tooltipOf(e.target);
    if (el && el === tooltipFor && !withinEl(el, e)) hideTooltip();
  });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape" && tooltipShown()) { escapeHandled(e); hideTooltip(); } }, true);
  window.addEventListener("scroll", function () { hideTooltip(); }, true);
  window.addEventListener("wheel", function () { hideTooltip(); }, { passive: true });
  window.addEventListener("resize", function () { hideTooltip(); });

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
    btn.setAttribute("aria-haspopup", "dialog");
    btn.setAttribute("aria-expanded", "false");
    var panel = document.createElement("div");
    panel.className = "kit-multi__panel";
    panel.id = "kit-multi-" + Math.random().toString(36).slice(2, 8);
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-label", label);
    btn.setAttribute("aria-controls", panel.id);
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
    wrap.addEventListener("keydown", function (e) { if (e.key === "Escape" && !panel.hidden) { escapeHandled(e); toggle(false); btn.focus(); } });
    wrap.addEventListener("focusout", function (e) { if (!panel.hidden && e.relatedTarget && !wrap.contains(e.relatedTarget)) toggle(false); });
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
  // data-kit-stamp-of="GLOBAL" (a time the page's data sets in a global, such as window.kitDataAsOf).
  // Shows "Data as of 14:00 (2 hours ago)" for today and "Data as of 9 Oct 2026, 14:00 (3 days ago)" for an
  // earlier day; data-kit-prefix changes the first words.
  function ago(ms) {
    var s = Math.round((ms - Date.now()) / 1000), a = Math.abs(s);
    var unit = a < 60 ? ["second", s] : a < 3600 ? ["minute", Math.round(s / 60)] : a < 86400 ? ["hour", Math.round(s / 3600)] : ["day", Math.round(s / 86400)];
    try { return new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }).format(unit[1], unit[0]); } catch (e) { return ""; }
  }
  // The stamp's time: the one given, else data-kit-stamp, else window.kitDataAsOf[data-kit-stamp-of];
  // null when there is none or it is not a date.
  function stampDate(el, when) {
    var v = when || el.getAttribute("data-kit-stamp");
    var of = el.getAttribute("data-kit-stamp-of");
    if (!v && of && window.kitDataAsOf) v = window.kitDataAsOf[of];
    var d = v ? new Date(v) : null;
    return d && !isNaN(d.getTime()) ? d : null;
  }
  // The time alone when it is today, the date first on any other day (CommonShared kit/stamp.js).
  function stampText(d) {
    var opts = d.toDateString() === new Date().toDateString() ? { timeStyle: "short" } : { dateStyle: "medium", timeStyle: "short" };
    try { return new Intl.DateTimeFormat(undefined, opts).format(d); } catch (e) { return d.toLocaleString(); }
  }
  function showStamp(el, when) {
    var d = stampDate(el, when);
    if (!d) return;
    if (when) el.setAttribute("data-kit-stamp", d.toISOString());
    var rel = ago(d.getTime());   // empty in a browser without relative time formats: no empty brackets
    el.textContent = (el.getAttribute("data-kit-prefix") || "Data as of") + " " + stampText(d) + (rel ? " (" + rel + ")" : "");
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

  // Menu (adapted from an open-source component library, MIT): a button with data-kit-menu opens the kit-menu__list next to
  // it; arrow keys move, Escape or a click beside it closes; "kit:menu" with detail.value on the kit-menu.
  function menuList(btn) { var m = btn.closest(".kit-menu"); return m ? m.querySelector(".kit-menu__list") : btn.nextElementSibling; }
  // The list's own rows: a submenu's rows belong to the submenu.
  function menuItems(list) { return Array.prototype.filter.call(list.querySelectorAll(".kit-menu__item:not([disabled])"), function (it) { return it.closest(".kit-menu__list") === list; }); }
  function closeMenus(except) {
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-menu][aria-expanded=true]"), function (b) {
      if (b === except) return;
      b.setAttribute("aria-expanded", "false");
      var l = menuList(b); if (l) { l.hidden = true; unplaceMenu(l); closeSubs(l); }
    });
  }
  // Submenus: <div class="kit-menu__sub"> holding a row with aria-haspopup="menu" and its own kit-menu__list.
  // ArrowRight, Enter or Space opens it on its first row, a pointer resting on the row for 100 ms too;
  // ArrowLeft or Escape closes only the submenu and goes back to its row.
  function subList(row) { var s = row.closest(".kit-menu__sub"); return s && s.querySelector(":scope > .kit-menu__list"); }
  function isSubRow(row) { return !!row && row.getAttribute("aria-haspopup") === "menu" && !!subList(row); }
  function closeSubs(list, except) {
    Array.prototype.forEach.call(list.querySelectorAll('.kit-menu__item[aria-haspopup="menu"][aria-expanded="true"]'), function (r) {
      if (except && (r === except || r.contains(except))) return;
      r.setAttribute("aria-expanded", "false");
      var l = subList(r); if (l) { l.hidden = true; closeSubs(l); }
    });
  }
  function openSub(row, focusFirst) {
    var l = subList(row), parent = row.closest(".kit-menu__list");
    if (!l) return;
    if (parent) closeSubs(parent, row);
    row.setAttribute("aria-expanded", "true");
    l.hidden = false;
    menuItems(l).forEach(function (it) { if (!it.hasAttribute("tabindex")) it.setAttribute("tabindex", "-1"); });
    if (focusFirst && menuItems(l)[0]) menuItems(l)[0].focus();
  }
  function closeSub(list) {
    var row = list.parentNode && list.parentNode.querySelector(':scope > .kit-menu__item[aria-haspopup="menu"]');
    if (!row) return false;
    row.setAttribute("aria-expanded", "false");
    list.hidden = true;
    closeSubs(list);
    row.focus();
    return true;
  }
  // Check and radio rows (role="menuitemcheckbox" / "menuitemradio" with aria-checked): a press turns them
  // and the menu stays open; a radio row turns off the others in its role="group" (else in its list).
  // "kit:menu" gets detail.checked.
  function checkRow(item) {
    var role = item.getAttribute("role");
    if (role !== "menuitemcheckbox" && role !== "menuitemradio") return false;
    var on = role === "menuitemradio" ? true : item.getAttribute("aria-checked") !== "true";
    if (role === "menuitemradio") {
      var scope = item.closest('[role="group"]') || item.closest(".kit-menu__list");
      Array.prototype.forEach.call(scope.querySelectorAll('[role="menuitemradio"]'), function (r) { if (r.closest(".kit-menu__list") === item.closest(".kit-menu__list")) r.setAttribute("aria-checked", "false"); });
    }
    item.setAttribute("aria-checked", String(on));
    var menu = item.closest(".kit-menu");
    if (menu) menu.dispatchEvent(new CustomEvent("kit:menu", { bubbles: true, detail: { value: item.getAttribute("data-value") || item.textContent.trim(), checked: on } }));
    return true;
  }
  function closestOf(target, selector) { return target.closest ? target.closest(selector) : null; }
  function toggleMenu(btn) {
    var list = menuList(btn), open = btn.getAttribute("aria-expanded") === "true";
    if (list) unplaceMenu(list);   // opened as a context menu before: back next to its button
    closeMenus(btn);
    btn.setAttribute("aria-expanded", String(!open));
    if (!list) return;
    list.hidden = open;
    if (open) return;
    // The arrow keys move between the rows, so the rows are not separate Tab stops.
    menuItems(list).forEach(function (it) { if (!it.hasAttribute("tabindex")) it.setAttribute("tabindex", "-1"); });
    var first = menuItems(list)[0];
    if (first) first.focus();
  }
  function pickMenuItem(item) {
    var menu = item.closest(".kit-menu"), list = item.closest(".kit-menu__list");
    var b2 = menu && menu.querySelector("[data-kit-menu]");
    var area = list && list.kitArea, back = list && list.kitBack;
    closeMenus();
    var detail = { value: item.getAttribute("data-value") || item.textContent.trim() };
    if (area) detail.target = area;   // opened as a context menu: the row or card it was opened on
    if (menu) menu.dispatchEvent(new CustomEvent("kit:menu", { bubbles: true, detail: detail }));
    focusBack(back, b2);
  }
  document.addEventListener("click", function (e) {
    var btn = closestOf(e.target, "[data-kit-menu]");
    if (btn) { toggleMenu(btn); return; }
    var item = closestOf(e.target, ".kit-menu__item");
    if (item && isSubRow(item)) { if (item.getAttribute("aria-expanded") === "true") closeSub(subList(item)); else openSub(item, true); return; }
    if (item && checkRow(item)) return;
    if (item) { pickMenuItem(item); return; }
    if (!closestOf(e.target, ".kit-menu__list")) closeMenus();
  });
  // A pointer resting on a submenu row opens it; on another row, the open submenu beside it closes.
  var subTimer = null;
  document.addEventListener("pointerover", function (e) {
    if (e.pointerType === "touch") return;
    var row = closestOf(e.target, ".kit-menu__item"), list = row && row.closest(".kit-menu__list");
    if (!list || list.hidden) return;
    clearTimeout(subTimer);
    subTimer = setTimeout(function () { if (isSubRow(row)) openSub(row, false); else closeSubs(list); }, 100);
  });
  // The menu's button: in its kit-menu, else the list's previous sibling when that is one.
  function menuButtonOf(list) {
    var box = list.closest(".kit-menu");
    if (box) return box.querySelector("[data-kit-menu]");
    var before = list.previousElementSibling;
    return before && before.hasAttribute("data-kit-menu") ? before : null;
  }
  // The item a key moves to (Arrow keys wrap round, Home and End), or undefined for other keys.
  function menuTarget(items, i, key) {
    var n = items.length;
    var places = { ArrowDown: (i + 1 + n) % n, ArrowUp: (i - 1 + n) % n, Home: 0, End: n - 1 };
    if (!Object.prototype.hasOwnProperty.call(places, key)) return undefined;
    return items[places[key]] || null;
  }
  // Type-ahead in menus and trees: a printable key moves to the next item whose text starts with what
  // was typed in the last 600 ms (one letter again steps through the items with that letter).
  var typed = "", typedAt = 0;
  function typeaheadKey(e) {
    var t = e.target, typing = t && (/^(input|textarea|select)$/.test(t.localName || "") || t.isContentEditable);
    return !typing && !!e.key && e.key.length === 1 && e.key !== " " && !e.ctrlKey && !e.metaKey && !e.altKey;
  }
  function typeahead(items, current, key, textOf) {
    var now = Date.now(), k = key.toLowerCase();
    typed = now - typedAt > 600 ? k : typed + k; typedAt = now;
    var at = items.indexOf(current), order = items.slice(at + 1).concat(items.slice(0, at + 1));
    var starts = function (want) { return function (it) { return (textOf ? textOf(it) : it.textContent || "").trim().toLowerCase().indexOf(want) === 0; }; };
    return order.filter(starts(typed))[0] || (typed.length > 1 ? null : order.filter(starts(k))[0]) || null;
  }
  document.addEventListener("keydown", function (e) {
    // ArrowDown or ArrowUp on a menu's button opens it on its first or last item (Enter and Space click it).
    var trigger = (e.key === "ArrowDown" || e.key === "ArrowUp") && closestOf(e.target, "[data-kit-menu]");
    if (trigger) {
      e.preventDefault();
      if (trigger.getAttribute("aria-expanded") !== "true") toggleMenu(trigger);
      var tl = menuList(trigger), ti = tl ? menuItems(tl) : [];
      if (ti.length) ti[e.key === "ArrowUp" ? ti.length - 1 : 0].focus();
      return;
    }
    var list = closestOf(e.target, ".kit-menu__list");
    if (!list) return;
    var row = closestOf(e.target, ".kit-menu__item");
    // Enter and Space click the row (a button): the click handler opens a submenu or turns a check row.
    if (isSubRow(row) && e.key === "ArrowRight") { e.preventDefault(); openSub(row, true); return; }
    var isSub = !!list.parentNode && !!list.parentNode.classList && list.parentNode.classList.contains("kit-menu__sub");
    if (isSub && (e.key === "ArrowLeft" || e.key === "Escape")) { e.preventDefault(); if (e.key === "Escape") escapeHandled(e); closeSub(list); return; }
    if (!isSub && (e.key === "ArrowLeft" || e.key === "ArrowRight") && menubarMove(list, e.key === "ArrowRight" ? 1 : -1)) { e.preventDefault(); return; }
    var items = menuItems(list);
    var to = menuTarget(items, items.indexOf(document.activeElement), e.key);
    if (to === undefined && typeaheadKey(e)) { to = typeahead(items, document.activeElement, e.key); if (!to) return; }
    if (to !== undefined) { e.preventDefault(); if (to) to.focus(); }
    else if (e.key === "Escape" || e.key === "Tab") { var mb = menuButtonOf(list), back = list.kitBack; closeMenus(); if (e.key === "Escape") { escapeHandled(e); focusBack(back, mb); } }
  });
  function focusBack(first, second) {
    var to = first && document.body && document.body.contains(first) && first.focus ? first : second;
    if (to && to.focus) to.focus();
  }

  // Context menu: data-kit-context on a row, card or area that holds a kit-menu (its visible "..." button:
  // the same actions for every hand), or data-kit-context="ID" of a kit-menu elsewhere. A right click,
  // Shift+F10 or the context menu key there opens that menu's list at the pointer (under the focused
  // element for a key), kept inside the window. It works and closes like the menu, and also closes on
  // scroll, wheel and resize; kit:menu then has detail.target, the element it was opened on.
  var contextList = null, contextKeyAt = 0;
  function contextMenuOf(area) {
    var id = area.getAttribute("data-kit-context");
    var m = id ? document.getElementById(id) : area.querySelector(".kit-menu");
    if (m && !m.classList.contains("kit-menu")) m = m.querySelector(".kit-menu") || m.closest(".kit-menu");
    return m && m.querySelector("[data-kit-menu]") ? m : null;
  }
  function unplaceMenu(list) {
    if (list !== contextList) return;
    ["position", "left", "top", "right", "bottom"].forEach(function (p) { list.style[p] = ""; });
    list.kitArea = null; list.kitBack = null; contextList = null;
  }
  function openContextMenu(area, x, y) {
    var menu = contextMenuOf(area), btn = menu && menu.querySelector("[data-kit-menu]"), list = btn && menuList(btn);
    if (!list) return false;
    var back = document.activeElement;
    closeMenus();
    btn.setAttribute("aria-expanded", "true");
    list.hidden = false;
    contextList = list; list.kitArea = area; list.kitBack = back && back !== document.body ? back : btn;
    placeAt(list, x, y);
    var first = menuItems(list)[0];
    if (first) first.focus();
    return true;
  }
  // A list fixed at x, y; to the left of or above the point when it would run past the window.
  function placeAt(list, x, y) {
    var s = list.style, edge = 8;
    s.position = "fixed"; s.right = "auto"; s.bottom = "auto"; s.left = "0px"; s.top = "0px";
    var w = list.offsetWidth, h = list.offsetHeight;
    s.left = Math.round(x + w > window.innerWidth - edge ? Math.max(edge, x - w) : x) + "px";
    s.top = Math.round(y + h > window.innerHeight - edge ? Math.max(edge, y - h) : y) + "px";
  }
  function contextArea(t) { return closestOf(t, ".kit-menu__list") ? null : closestOf(t, "[data-kit-context]"); }
  document.addEventListener("contextmenu", function (e) {
    var area = contextArea(e.target);
    if (!area) return;
    if (Date.now() - contextKeyAt < 300) { e.preventDefault(); return; }   // the key already opened it
    var x = e.clientX, y = e.clientY;
    if (!x && !y) { var r = (e.target.getBoundingClientRect ? e.target : area).getBoundingClientRect(); x = r.left; y = r.bottom; }   // from the keyboard
    if (openContextMenu(area, x, y)) e.preventDefault();
  });
  document.addEventListener("keydown", function (e) {
    if (!((e.key === "F10" && e.shiftKey) || e.key === "ContextMenu")) return;
    var area = contextArea(e.target);
    if (!area) return;
    var r = (e.target.getBoundingClientRect ? e.target : area).getBoundingClientRect();
    if (openContextMenu(area, r.left, r.bottom)) { e.preventDefault(); contextKeyAt = Date.now(); }
  });
  function contextOpen() { return !!contextList && !contextList.hidden; }
  function inContext(e) { return !!(e && e.target && e.target.nodeType === 1 && contextList.contains(e.target)); }
  function closeContext(e) { if (contextOpen() && !inContext(e)) closeMenus(); }
  window.addEventListener("scroll", closeContext, true);
  window.addEventListener("wheel", closeContext, { passive: true });
  window.addEventListener("resize", function () { closeContext(); });

  // Icon toolbar (adapted from an open-source component library, MIT): data-kit-iconbar="single" (one pressed) or "multiple";
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

  // Avatars (adapted from an open-source component library, MIT): data-kit-avatar="NAME" writes the initials and gives every
  // name its own chart colour (the same name always the same colour); an <img> inside stays.
  // The first letters of the first and the last word.
  function initialsOf(name) {
    var words = name.split(/\s+/).filter(Boolean);
    var last = words.length > 1 ? words[words.length - 1].charAt(0) : "";
    return ((words[0] || "").charAt(0) + last).toUpperCase();
  }
  // A chart colour (1-6) for a name, always the same one.
  function nameColor(name) {
    var h = 0;
    for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) | 0;
    return (Math.abs(h) % 6) + 1;
  }
  function setupAvatar(el) {
    var name = (el.getAttribute("data-kit-avatar") || "").trim();
    if (!name || el.kitAvatar === name) return;
    el.kitAvatar = name;
    var img = el.querySelector("img");
    if (!img) el.textContent = initialsOf(name);
    // A photo that fails to load falls back to the initials (once; no broken-image icon).
    else if (!img.kitAvatarFallback) {
      img.kitAvatarFallback = true;
      var fallback = function () { if (img.parentNode === el) el.textContent = initialsOf(el.kitAvatar || name); };
      if (img.complete && img.naturalWidth === 0 && img.getAttribute("src")) fallback();
      else img.addEventListener("error", fallback);
    }
    el.style.setProperty("--kit-avatar-color", "var(--kit-chart-" + nameColor(name) + ")");
    el.setAttribute("title", name);
    // aria-hidden="true": the name is written beside the avatar, so it is not read twice.
    if (!el.hasAttribute("aria-label") && el.getAttribute("aria-hidden") !== "true") { el.setAttribute("role", "img"); el.setAttribute("aria-label", name); }
  }

  // Two values on one slider: data-kit-slider-range with data-min, data-max, data-step, data-from, data-to and
  // data-unit (shown and read out after the value); "kit:slide" with detail.from and detail.to; the values
  // show under it.
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
    var from = num("data-from", min), to = num("data-to", max), unit = el.getAttribute("data-unit") || "";
    var a = mk(Math.min(from, to), "Lowest " + name), b = mk(Math.max(from, to), "Highest " + name);
    // A screen reader hears the value with its unit ("45 min"), not the bare number.
    var said = function (v) { return v.toLocaleString() + (unit ? " " + unit : ""); };
    var out = document.createElement("div");
    out.className = "kit-slider__value";
    out.setAttribute("aria-live", "polite");
    el.parentNode.insertBefore(out, el.nextSibling);
    var draw = function (send) {
      var lo = Math.min(+a.value, +b.value), hi = Math.max(+a.value, +b.value);
      fill.style.left = ((lo - min) / (max - min || 1)) * 100 + "%";
      fill.style.width = ((hi - lo) / (max - min || 1)) * 100 + "%";
      out.textContent = lo.toLocaleString() + " - " + said(hi);
      a.setAttribute("aria-valuetext", said(lo)); b.setAttribute("aria-valuetext", said(hi));
      el.setAttribute("data-from", lo); el.setAttribute("data-to", hi);
      if (send) el.dispatchEvent(new CustomEvent("kit:slide", { bubbles: true, detail: { from: lo, to: hi } }));
    };
    // The thumbs stop at each other, so "Lowest" never holds the higher value.
    a.addEventListener("input", function () { if (+a.value > +b.value) a.value = b.value; draw(true); });
    b.addEventListener("input", function () { if (+b.value < +a.value) b.value = a.value; draw(true); });
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
        x.addEventListener("click", function () { values.splice(i, 1); draw(true); announce("Removed " + v); input.focus(); });
        t.appendChild(x);
        el.insertBefore(t, input);
      });
      if (hidden) hidden.value = values.join(",");
      el.setAttribute("data-tags", values.join(","));
      if (send) el.dispatchEvent(new CustomEvent("kit:tags", { bubbles: true, detail: { values: values.slice() } }));
    }
    function add(text) {
      var v = text.replace(/,/g, " ").trim();
      if (v && values.indexOf(v) < 0) { values.push(v); draw(true); announce("Added " + v); }
      input.value = "";
    }
    input.addEventListener("keydown", function (e) {
      if (e.isComposing) return;   // a key that ends an IME composition is not Enter
      if (e.key === "Enter" || e.key === ",") { e.preventDefault(); add(input.value); }
      else if (e.key === "Backspace" && !input.value && values.length) { var gone = values.pop(); draw(true); announce("Removed " + gone); }
    });
    input.addEventListener("change", function () { if (input.value.indexOf(",") < 0 && input.value) add(input.value); });
    el.addEventListener("click", function (e) { if (e.target === el) input.focus(); });
    draw(false);
  }

  // Board: drag a kit-board__card to another data-kit-board list, or focus it and press Alt with an arrow
  // key (left and right: the next list, up and down: the order); "kit:move" with detail.id, from, to and index.
  var dragCard = null, dragFrom = null;
  function boardLists(card) { var b = card.closest(".kit-board"); return b ? Array.prototype.slice.call(b.querySelectorAll("[data-kit-board]")) : []; }
  // A column's name: its kit-board__title without the count badge, else its data-kit-board.
  function boardColumnName(list) {
    var col = list.closest(".kit-board__column"), title = col && col.querySelector(".kit-board__title");
    if (!title) return list.getAttribute("data-kit-board") || "";
    var copy = title.cloneNode(true);
    Array.prototype.forEach.call(copy.querySelectorAll(".kit-badge"), function (b) { b.parentNode.removeChild(b); });
    return copy.textContent.trim() || list.getAttribute("data-kit-board") || "";
  }
  function moved(card, from) {
    var to = card.parentNode;
    var name = (card.getAttribute("aria-label") || card.textContent).trim().replace(/\s+/g, " ").slice(0, 80);
    announce("Moved " + name + " to " + boardColumnName(to) + ", position " + (Array.prototype.indexOf.call(to.children, card) + 1) + " of " + to.children.length);
    card.dispatchEvent(new CustomEvent("kit:move", { bubbles: true, detail: { id: card.getAttribute("data-id"), from: from.getAttribute("data-kit-board"), to: to.getAttribute("data-kit-board"), index: Array.prototype.indexOf.call(to.children, card) } }));
  }
  // Alt+Arrow keys: up and down within the card's list, left and right into the next list. True when it moved.
  function moveCardByKey(card, key) {
    var from = card.parentNode;
    if (key === "ArrowUp" && card.previousElementSibling) { from.insertBefore(card, card.previousElementSibling); return true; }
    if (key === "ArrowDown" && card.nextElementSibling) { from.insertBefore(card.nextElementSibling, card); return true; }
    if (key !== "ArrowLeft" && key !== "ArrowRight") return false;
    var lists = boardLists(card);
    var to = lists.length ? lists[lists.indexOf(from) + (key === "ArrowRight" ? 1 : -1)] : null;
    if (!to) return false;
    to.appendChild(card);
    return true;
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
      var from = card.parentNode;
      if (!moveCardByKey(card, e.key)) return;
      card.focus();
      moved(card, from);
    });
  }
  function setupBoardList(list) {
    if (list.kitList) return;
    list.kitList = true;
    // A named region per column (its title), and its list named the same, unless the page named them.
    var colBox = list.closest(".kit-board__column"), colTitle = colBox && colBox.querySelector(".kit-board__title");
    if (colTitle) {
      var tid = idOf(colTitle, "board-title");
      if (!colBox.hasAttribute("aria-label") && !colBox.hasAttribute("aria-labelledby")) colBox.setAttribute("aria-labelledby", tid);
      if (!list.hasAttribute("aria-label") && !list.hasAttribute("aria-labelledby")) list.setAttribute("aria-labelledby", tid);
    }
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
  // The days are one tab stop: arrow keys move a day or a week, Home and End go to the week's first and last
  // day, PageUp and PageDown a month (with Shift a year); Today goes back to this month. The week starts on
  // data-week-start (0 = Sunday ... 6), else --kit-week-start, else the day the browser's language starts on.
  function calendarWeekStart(el) {
    var own = parseInt(el.getAttribute("data-week-start"), 10);
    if (own >= 0 && own <= 6) return own;
    var css = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--kit-week-start"), 10);
    return css >= 0 && css <= 6 ? css : localeWeekStart();
  }
  // The first day of the week in the browser's language (0 = Sunday); Monday without week data.
  function localeWeekStart() {
    try {
      var loc = new Intl.Locale(navigator.language), info = loc.getWeekInfo ? loc.getWeekInfo() : loc.weekInfo;
      if (info && info.firstDay >= 1 && info.firstDay <= 7) return info.firstDay % 7;   // 7 = Sunday
    } catch (e) { /* a browser without week data: Monday */ }
    return 1;
  }
  function calendarTitle(first, y, m) {
    try { return new Intl.DateTimeFormat(undefined, { month: "long", year: "numeric" }).format(first); } catch (e) { return y + "-" + (m + 1); }
  }
  function calendarHead(title) {
    var head = document.createElement("div");
    head.className = "kit-calendar__head";
    head.innerHTML = '<button class="kit-btn kit-btn--sm kit-btn--ghost" type="button" data-step="-1">Previous</button><h3 class="kit-calendar__title" aria-live="polite"></h3><span class="kit-calendar__nav"><button class="kit-btn kit-btn--sm kit-btn--ghost" type="button" data-today>Today</button><button class="kit-btn kit-btn--sm kit-btn--ghost" type="button" data-step="1">Next</button></span>';
    head.querySelector("h3").textContent = title;
    return head;
  }
  // The weekday names over the columns, from the week's first day (0 = Sunday).
  function calendarWeekdays(grid, start) {
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
  }
  function calendarEvent(ev) {
    var s = document.createElement("span");
    s.className = "kit-calendar__event" + (/^(ok|warn|error)$/.test(ev.tone || "") ? " kit-calendar__event--" + ev.tone : "");
    s.textContent = ev.title;
    return s;
  }
  // One day's button: its number, up to three events and "+N" for the rest, a full date as its name.
  function calendarDay(day, iso, st, m, today) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = "kit-calendar__day" + (day.getMonth() !== m ? " is-other" : "") + (iso === today ? " is-today" : "");
    b.setAttribute("data-date", iso);
    b.tabIndex = iso === st.focus ? 0 : -1;
    if (iso === today) b.setAttribute("aria-current", "date");
    var num = document.createElement("span"); num.className = "kit-calendar__num"; num.textContent = day.getDate(); b.appendChild(num);
    var evs = (st.events || []).filter(function (ev) { return String(ev.date).slice(0, 10) === iso; });
    calendarDayEvents(b, evs);
    b.setAttribute("aria-label", calendarDayLabel(day, iso, evs.length));
    return b;
  }
  // Up to three events on a day's button, and "+N" for the rest.
  function calendarDayEvents(b, evs) {
    evs.slice(0, 3).forEach(function (ev) { b.appendChild(calendarEvent(ev)); });
    if (evs.length > 3) { var more = document.createElement("span"); more.className = "kit-calendar__event"; more.textContent = "+" + (evs.length - 3); b.appendChild(more); }
  }
  // A day's name: "Today, " for today (not only its look), its full date, and how many items it has.
  function calendarDayLabel(day, iso, n) {
    var label;
    try { label = new Intl.DateTimeFormat(undefined, { dateStyle: "full" }).format(day); } catch (e) { label = iso; }
    if (iso === isoDay(new Date())) label = "Today, " + label;
    return label + (n ? ", " + n + " item" + (n > 1 ? "s" : "") : "");
  }
  function calendarDraw(el) {
    var st = el.kitCal, y = st.year, m = st.month;
    var start = calendarWeekStart(el);
    var first = new Date(y, m, 1), lead = (first.getDay() - start + 7) % 7, today = isoDay(new Date());
    var title = calendarTitle(first, y, m);
    var cells = Math.ceil((lead + new Date(y, m + 1, 0).getDate()) / 7) * 7;
    // The day that takes the Tab key: the one last focused while it is on show, else today, else the 1st.
    var shown = function (iso) { var t = new Date(+iso.slice(0, 4), +iso.slice(5, 7) - 1, +iso.slice(8, 10)).getTime(); return t >= new Date(y, m, 1 - lead).getTime() && t <= new Date(y, m, cells - lead).getTime(); };
    if (!st.focus || !shown(st.focus)) st.focus = today.slice(0, 7) === isoDay(first).slice(0, 7) ? today : isoDay(first);
    el.innerHTML = "";
    el.appendChild(calendarHead(title));
    var grid = document.createElement("div");
    grid.className = "kit-calendar__grid";
    grid.setAttribute("role", "group");
    grid.setAttribute("aria-label", title);
    calendarWeekdays(grid, start);
    for (var c = 0; c < cells; c++) {
      var day = new Date(y, m, 1 - lead + c);
      grid.appendChild(calendarDay(day, isoDay(day), st, m, today));
    }
    el.appendChild(grid);
  }
  // Previous or next month (a button with data-step="-1" or "1"): drawn again, "kit:month".
  // The month on show: drawn again, "kit:month" when it is another month than before.
  function calendarShow(el, y, m) {
    var st = el.kitCal, changed = st.year !== y || st.month !== m;
    st.year = y; st.month = m;
    calendarDraw(el);
    if (changed) el.dispatchEvent(new CustomEvent("kit:month", { bubbles: true, detail: { month: y + "-" + ("0" + (m + 1)).slice(-2) } }));
  }
  // Drawing replaces the buttons, so the one that was pressed gets the focus back.
  function calendarRefocus(el, selector) { var b = el.querySelector(selector); if (b) b.focus(); }
  function calendarStep(el, stepBtn) {
    var by = stepBtn.getAttribute("data-step"), d = new Date(el.kitCal.year, el.kitCal.month + parseInt(by, 10), 1);
    calendarShow(el, d.getFullYear(), d.getMonth());
    calendarRefocus(el, '[data-step="' + by + '"]');
  }
  function calendarToday(el) {
    var now = new Date();
    el.kitCal.focus = isoDay(now);
    calendarShow(el, now.getFullYear(), now.getMonth());
    calendarRefocus(el, "[data-today]");
  }
  // One day takes the Tab key (el.kitCal.focus); the others are reached with the keys below.
  function calendarRove(el) {
    Array.prototype.forEach.call(el.querySelectorAll(".kit-calendar__day"), function (b) { b.tabIndex = b.getAttribute("data-date") === el.kitCal.focus ? 0 : -1; });
  }
  function calendarGo(el, to, turn) {
    var iso = isoDay(to), at = '[data-date="' + iso + '"]';
    el.kitCal.focus = iso;
    if (turn || !el.querySelector(at)) calendarShow(el, to.getFullYear(), to.getMonth()); else calendarRove(el);
    calendarRefocus(el, at);
  }
  function calendarKey(el, e) {
    var day = e.target.closest && e.target.closest(".kit-calendar__day");
    if (!day || e.altKey || e.ctrlKey || e.metaKey) return;
    var p = day.getAttribute("data-date").split("-"), y = +p[0], m = +p[1] - 1, d = +p[2];
    var col = (new Date(y, m, d).getDay() - calendarWeekStart(el) + 7) % 7;
    var steps = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7, Home: -col, End: 6 - col };
    if (Object.prototype.hasOwnProperty.call(steps, e.key)) { e.preventDefault(); calendarGo(el, new Date(y, m, d + steps[e.key]), false); return; }
    var to = calendarPageTo(e, y, m, d);
    if (!to) return;
    e.preventDefault();
    calendarGo(el, to, true);
  }
  // PageUp and PageDown: the same day a month earlier or later (with Shift a year), or that month's last day.
  function calendarPageTo(e, y, m, d) {
    if (e.key !== "PageUp" && e.key !== "PageDown") return null;
    var by = (e.key === "PageUp" ? -1 : 1) * (e.shiftKey ? 12 : 1);
    return new Date(y, m + by, Math.min(d, new Date(y, m + by + 1, 0).getDate()));   // 31 March -> 30 April
  }
  // A day clicked: "kit:day" with that day's events.
  function calendarPick(el, day) {
    var date = day.getAttribute("data-date");
    var events = (el.kitCal.events || []).filter(function (ev) { return String(ev.date).slice(0, 10) === date; });
    el.dispatchEvent(new CustomEvent("kit:day", { bubbles: true, detail: { date: date, events: events } }));
  }
  function calendarClick(el, e) {
    var stepBtn = e.target.closest("[data-step]");
    if (stepBtn) { calendarStep(el, stepBtn); return; }
    if (e.target.closest("[data-today]")) { calendarToday(el); return; }
    var day = e.target.closest(".kit-calendar__day");
    if (day) calendarPick(el, day);
  }
  // The month asked for, from opts.month or data-month ("YYYY-MM"): { year, month } or null.
  function calendarMonthOf(el, opts) {
    var mm = /^(\d{4})-(\d{2})$/.exec((opts && opts.month) || el.getAttribute("data-month") || "");
    return mm ? { year: +mm[1], month: +mm[2] - 1 } : null;
  }
  function calendarListen(el) {
    el.addEventListener("click", function (e) { calendarClick(el, e); });
    el.addEventListener("keydown", function (e) { calendarKey(el, e); });
    el.addEventListener("focusin", function (e) {
      var day = e.target.closest && e.target.closest(".kit-calendar__day");
      if (day && day.getAttribute("data-date") !== el.kitCal.focus) { el.kitCal.focus = day.getAttribute("data-date"); calendarRove(el); }
    });
  }
  function setupCalendar(el, opts) {
    var now = new Date(), at = calendarMonthOf(el, opts);
    if (!el.kitCal) {
      el.kitCal = { year: at ? at.year : now.getFullYear(), month: at ? at.month : now.getMonth(), events: [] };
      calendarListen(el);
    }
    if (opts && at) { el.kitCal.year = at.year; el.kitCal.month = at.month; }
    if (opts && opts.events) el.kitCal.events = opts.events;
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
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && !e.defaultPrevented && nav.classList.contains("is-open")) { e.preventDefault(); set(false); btn.focus(); } });
    set(false);
  }

  // Command palette: a dialog of the kit with data-kit-palette and aria-label="Commands" (see the command
  // palette section of the examples): a search field, a list of search rows (data-value; the shortcut in
  // the row's meta part) and an empty state for no match. Ctrl+K (Cmd+K) opens it from anywhere but a field,
  // a button with data-kit-open="ID" too. Typing filters (the number of rows is read out), the arrow keys
  // move, Enter runs the row: "kit:command" with detail.value and detail.text on the dialog (a row with a
  // link follows it). Escape clears the text first, then closes; the focus goes back where it was.
  var paletteCount = 0;
  function setupPalette(d) {
    if (d.kitPalette) return;
    var input = d.querySelector("input"), list = d.querySelector(".kit-search__list"), empty = d.querySelector(".kit-empty");
    if (!input || !list) return;
    d.kitPalette = true;
    if (!list.id) list.id = "palette-list-" + (++paletteCount);
    list.setAttribute("role", "listbox");
    input.setAttribute("role", "combobox");
    input.setAttribute("aria-autocomplete", "list");
    input.setAttribute("aria-controls", list.id);
    input.setAttribute("autocomplete", "off");
    if (!input.getAttribute("aria-label") && !input.id) input.setAttribute("aria-label", d.getAttribute("aria-label") || "Command");
    var rows = function () { return Array.prototype.slice.call(list.querySelectorAll(".kit-search__item")); };
    var shown = function () { return rows().filter(function (r) { return !r.hidden; }); };
    var active = null;
    rows().forEach(function (r, n) { r.setAttribute("role", "option"); if (!r.id) r.id = list.id + "-" + n; });
    function markRow(r) {
      active = r || null;
      rows().forEach(function (x) { x.classList.toggle("is-active", x === active); x.setAttribute("aria-selected", String(x === active)); });
      if (active) { input.setAttribute("aria-activedescendant", active.id); if (active.scrollIntoView && d.open) active.scrollIntoView({ block: "nearest" }); }
      else input.removeAttribute("aria-activedescendant");
    }
    function filterRows(quiet) {
      var q = input.value.trim().toLowerCase();
      rows().forEach(function (r) { r.hidden = q !== "" && r.textContent.toLowerCase().indexOf(q) < 0; });
      var v = shown();
      list.hidden = !v.length;
      if (empty) empty.hidden = v.length > 0;
      input.setAttribute("aria-expanded", String(v.length > 0));
      markRow(v[0]);
      if (quiet !== true) announce(v.length === 1 ? "1 result" : v.length + " results");
    }
    function run(r) {
      var label = r.cloneNode(true), meta = label.querySelector(".kit-search" + "__meta");   // put together: the page brings its rule
      if (meta) meta.parentNode.removeChild(meta);
      var link = r.querySelector("a[href]");
      closePanel(d);
      d.dispatchEvent(new CustomEvent("kit:command", { bubbles: true, detail: { value: r.getAttribute("data-value") || label.textContent.trim(), text: label.textContent.trim() } }));
      if (link) link.click();
    }
    input.addEventListener("input", filterRows);
    input.addEventListener("keydown", function (e) {
      if (e.isComposing) return;   // Enter that ends a composition (IME) runs nothing
      var v = shown(), i = v.indexOf(active);
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        if (v.length) markRow(v[(i + (e.key === "ArrowDown" ? 1 : -1) + v.length) % v.length]);
      } else if (e.key === "Enter" && active && !active.hidden) { e.preventDefault(); run(active); }
      else if (e.key === "Escape" && input.value) { escapeHandled(e); input.value = ""; filterRows(); }
    });
    list.addEventListener("mousedown", function (e) { e.preventDefault(); });   // the field keeps the focus
    list.addEventListener("mousemove", function (e) { var r = closestOf(e.target, ".kit-search__item"); if (r && r !== active) markRow(r); });
    list.addEventListener("click", function (e) { var r = closestOf(e.target, ".kit-search__item"); if (r && !r.hidden) run(r); });
    d.addEventListener("kit:open", function () { input.value = ""; filterRows(true); input.focus(); });
    d.addEventListener("close", function () { var b = d.kitBack; d.kitBack = null; if (b && b.focus && document.body.contains(b)) b.focus(); });
    filterRows(true);
  }
  // Ctrl+K or Cmd+K, without Alt or Shift.
  function paletteKey(e) {
    var mod = e.ctrlKey || e.metaKey, extra = e.altKey || e.shiftKey;
    return mod && !extra && String(e.key).toLowerCase() === "k";
  }
  document.addEventListener("keydown", function (e) {
    if (!paletteKey(e)) return;
    var d = document.querySelector("dialog[data-kit-palette]");
    if (!d) return;
    if (d.open) { e.preventDefault(); closePanel(d); return; }
    if (closestOf(e.target, "input, textarea, select, [contenteditable]")) return;   // a field keeps its own keys
    e.preventDefault();
    setupPalette(d);
    d.kitBack = document.activeElement;
    openPanel(d);
  });

  // Numbers, percentages, dates and times the same on every page (the page's language, html lang,
  // decides the separators): KitUI.format.number(v, { decimals }), percent(v, decimals) (v as 0..100;
  // one decimal unless whole), date(v, { time }) -> "9 Oct 2026" / "9 Oct 2026, 14:00", relative(v)
  // -> "2 hours ago"; "-" for what is not a number or date.
  function pageLang() { return document.documentElement.lang || undefined; }
  function noNumber(v, n) { return v === null || v === undefined || v === "" || !isFinite(n); }
  var format = {
    number: function (v, opts) {
      var n = Number(v);
      if (noNumber(v, n)) return "-";
      var d = opts && opts.decimals;
      return n.toLocaleString(pageLang(), d === undefined ? { maximumFractionDigits: 2 } : { minimumFractionDigits: d, maximumFractionDigits: d });
    },
    percent: function (v, decimals) {
      var n = Number(v);
      if (noNumber(v, n)) return "-";
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

  // Loading text that changes (adapted from an open-source component library, MIT; toned down): data-kit-cycle="First|Second|Third"
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

  // Tree (<ul class="kit-tree" role="tree" data-kit-tree>): every li is a treeitem; one with a nested
  // ul is a branch (aria-expanded) and gets a toggle button in its row; the arrow keys move and open or
  // close, Home and End jump, Enter or Space select (aria-selected on one item; "kit:select" on the
  // tree with detail.value from data-value or the row's text). One tab stop (roving tabindex).
  function treeRows(tree) {
    return Array.prototype.slice.call(tree.querySelectorAll("li")).filter(function (li) {
      for (var p = li.parentElement; p && p !== tree; p = p.parentElement) { if (p.tagName === "LI" && p.getAttribute("aria-expanded") === "false") return false; }
      return true;
    }).map(function (li) { return li.querySelector(":scope > .kit-tree__row"); }).filter(Boolean);
  }
  // An item's row (made from its text when the item has none).
  function treeRowOf(li) {
    var row = li.querySelector(":scope > .kit-tree__row");
    if (row) return row;
    row = document.createElement("div"); row.className = "kit-tree__row";
    while (li.firstChild && li.firstChild.tagName !== "UL") row.appendChild(li.firstChild);
    li.insertBefore(row, li.firstChild);
    return row;
  }
  function armTreeBranch(li, row, group) {
    if (!group.getAttribute("role")) group.setAttribute("role", "group");
    if (!li.hasAttribute("aria-expanded")) li.setAttribute("aria-expanded", "false");
    if (row.querySelector(".kit-tree__toggle")) return;
    var t = document.createElement("button");
    t.type = "button"; t.className = "kit-tree__toggle"; t.tabIndex = -1;
    t.setAttribute("aria-label", "Open or close");
    t.setAttribute("aria-hidden", "true");   // screen readers get aria-expanded on the treeitem, not one more "Open or close" per row
    row.insertBefore(t, row.firstChild);
  }
  // An item: its role, its row, a toggle for a branch and a spacer for a leaf.
  function armTreeItem(li) {
    if (!li.getAttribute("role")) li.setAttribute("role", "treeitem");
    var row = treeRowOf(li);
    var group = li.querySelector(":scope > ul");
    if (group) armTreeBranch(li, row, group);
    else if (!row.querySelector(".kit-tree__spacer, .kit-tree__toggle")) {
      var s = document.createElement("span"); s.className = "kit-tree__spacer"; s.setAttribute("aria-hidden", "true"); row.insertBefore(s, row.firstChild);
    }
    row.tabIndex = -1;
  }
  function setupTree(tree) {
    if (tree.kitTree) return;
    tree.kitTree = true;
    if (!tree.getAttribute("role")) tree.setAttribute("role", "tree");
    Array.prototype.forEach.call(tree.querySelectorAll("li"), function (li) { armTreeItem(li); });
    var roving = function (current) {
      var rows = treeRows(tree), cur = current || rows.filter(function (r) { return r.parentElement.getAttribute("aria-selected") === "true"; })[0] || rows[0];
      rows.forEach(function (r) { r.tabIndex = r === cur ? 0 : -1; });
    };
    var toggle = function (li, open) { if (li.querySelector(":scope > ul")) li.setAttribute("aria-expanded", String(open)); };
    var select = function (row) {
      Array.prototype.forEach.call(tree.querySelectorAll('li[aria-selected="true"]'), function (li) { li.removeAttribute("aria-selected"); });
      var li = row.parentElement;
      li.setAttribute("aria-selected", "true");
      roving(row);
      tree.dispatchEvent(new CustomEvent("kit:select", { bubbles: true, detail: { value: li.getAttribute("data-value") || row.textContent.trim(), item: li } }));
    };
    tree.addEventListener("click", function (e) {
      var tog = e.target.closest(".kit-tree__toggle");
      var row = e.target.closest(".kit-tree__row");
      if (!row || !tree.contains(row)) return;
      var li = row.parentElement;
      if (tog) { toggle(li, li.getAttribute("aria-expanded") !== "true"); roving(row); row.focus(); return; }
      select(row);
      row.focus();
    });
    var go = function (r) { if (r) { roving(r); r.focus(); } };
    // Right opens a closed branch, else goes into it; Left closes an open branch, else goes to its parent.
    var right = function (k) {
      if (!k.branch) return;
      if (k.li.getAttribute("aria-expanded") !== "true") toggle(k.li, true); else go(treeRows(tree)[k.i + 1]);
    };
    var left = function (k) {
      if (k.branch && k.li.getAttribute("aria-expanded") === "true") { toggle(k.li, false); return; }
      var up = k.li.parentElement && k.li.parentElement.closest("li");
      if (up && tree.contains(up)) go(up.querySelector(":scope > .kit-tree__row"));
    };
    var keys = {
      ArrowDown: function (k) { go(k.rows[k.i + 1]); },
      ArrowUp: function (k) { go(k.rows[k.i - 1]); },
      Home: function (k) { go(k.rows[0]); },
      End: function (k) { go(k.rows[k.rows.length - 1]); },
      ArrowRight: right,
      ArrowLeft: left,
      Enter: function (k) { select(k.row); },
      " ": function (k) { select(k.row); }
    };
    tree.addEventListener("keydown", function (e) {
      var row = e.target.closest && e.target.closest(".kit-tree__row");
      if (row && typeaheadKey(e)) { var t = typeahead(treeRows(tree), row, e.key); if (t) { e.preventDefault(); go(t); } return; }
      if (!row || !Object.prototype.hasOwnProperty.call(keys, e.key)) return;
      var li = row.parentElement, rows = treeRows(tree);
      e.preventDefault();
      keys[e.key]({ row: row, li: li, rows: rows, i: rows.indexOf(row), branch: !!li.querySelector(":scope > ul") });
    });
    roving();
  }

  // Popover (a small panel from a button): data-kit-popover="ID" on the button toggles #ID (hidden),
  // keeps aria-expanded, closes on Escape or a click beside it and gives focus back; "kit:open" and
  // "kit:close" on the panel.
  function popoverOf(btn) { return document.getElementById(btn.getAttribute("data-kit-popover")); }
  function closePopovers(except) {
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-popover][aria-expanded=true]"), function (b) {
      if (b === except) return;
      var p = popoverOf(b);
      b.setAttribute("aria-expanded", "false");
      if (p && !p.hidden) { p.hidden = true; p.dispatchEvent(new CustomEvent("kit:close", { bubbles: true })); }
    });
  }
  function togglePopover(btn) {
    var p = popoverOf(btn);
    if (!p) return;
    var open = btn.getAttribute("aria-expanded") === "true";
    closePopovers(btn);
    btn.setAttribute("aria-expanded", String(!open));
    if (!btn.getAttribute("aria-controls")) btn.setAttribute("aria-controls", p.id);
    // A non-modal dialog named by its button (no aria-modal, no focus trap), unless the page gave it a role.
    if (!p.getAttribute("role")) p.setAttribute("role", "dialog");
    if (p.getAttribute("role") === "dialog" && !p.getAttribute("aria-label") && !p.getAttribute("aria-labelledby")) p.setAttribute("aria-labelledby", idOf(btn, "popover-btn"));
    p.hidden = open;
    if (open) { p.dispatchEvent(new CustomEvent("kit:close", { bubbles: true })); return; }
    p.dispatchEvent(new CustomEvent("kit:open", { bubbles: true }));
    var f = p.querySelector("input, select, textarea, button, a[href], [tabindex]:not([tabindex='-1'])");
    if (f) f.focus(); else { p.tabIndex = -1; p.focus(); }
  }
  document.addEventListener("click", function (e) {
    var btn = closestOf(e.target, "[data-kit-popover]");
    if (btn) { togglePopover(btn); return; }
    if (!closestOf(e.target, ".kit-popover")) closePopovers();
  });
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Escape" || e.defaultPrevented || e.isComposing) return;
    var open = Array.prototype.slice.call(document.querySelectorAll("[data-kit-popover][aria-expanded=true]"));
    if (!open.length) return;
    escapeHandled(e);
    var inside = e.target.closest && e.target.closest(".kit-popover");
    closePopovers();
    var back = inside ? open.filter(function (b) { return popoverOf(b) === inside; })[0] : open[open.length - 1];
    if (back) back.focus();
  });

  // Confirm and alert boxes, KitUI's confirm(text, { title, ok, cancel, danger }) and alert(text, { title, ok }):
  // a kit dialog instead of the browser's own boxes; confirm gives a promise of true or false, alert a
  // promise once it is closed. (No "KitUI." call written here: a one-file page counts the kit's classes by text.)
  function dialogBox(text, opts, buttons) {
    opts = opts || {};
    var d = document.createElement("dialog");
    d.className = DIALOG;
    d.setAttribute("role", "alertdialog");
    if (opts.title) { var h = document.createElement("h3"); h.className = "kit-" + "h3"; h.textContent = opts.title; d.appendChild(h); d.setAttribute("aria-labelledby", h.id = "kit-box-" + (++boxCount)); }
    var p = document.createElement("p"); p.textContent = String(text); p.id = "kit-box-" + (++boxCount); d.appendChild(p);
    d.setAttribute("aria-describedby", p.id);
    if (!opts.title) d.setAttribute("aria-labelledby", p.id);
    var row = document.createElement("div"); row.className = DIALOG + "__actions";   // put together: a page gets these styles through the confirm/alert hook, not from this token
    buttons.forEach(function (b) {
      var btn = document.createElement("button"); btn.type = "button";
      btn.className = "kit-btn" + (b.kind ? " kit-btn--" + b.kind : "");
      btn.textContent = b.label; btn.setAttribute("data-value", b.value);
      row.appendChild(btn);
    });
    d.appendChild(row);
    document.body.appendChild(d);
    return new Promise(function (resolve) {
      var done = false;
      var finish = function (v) { if (done) return; done = true; resolve(v); closePanel(d); if (d.parentNode) d.parentNode.removeChild(d); };
      row.addEventListener("click", function (e) { var b = e.target.closest("button"); if (b) finish(b.getAttribute("data-value") === "ok"); });
      d.addEventListener("cancel", function (e) { e.preventDefault(); finish(false); });
      d.addEventListener("close", function () { finish(false); });
      openPanel(d);
      var first = row.querySelector(".kit-btn--danger") ? row.querySelector('[data-value="cancel"]') : row.querySelector(".kit-btn--primary") || row.querySelector("button");
      if (first) first.focus();
    });
  }
  // One box at a time: a second question waits until the first is answered (it opens at once when none is open).
  var boxCount = 0, boxOpen = false, boxWaiting = [];
  function queuedBox(text, opts, buttons) {
    return new Promise(function (resolve) {
      var start = function () {
        boxOpen = true;
        dialogBox(text, opts, buttons).then(function (v) {
          boxOpen = false;
          var next = boxWaiting.shift();
          if (next) next();
          resolve(v);
        });
      };
      if (boxOpen) boxWaiting.push(start); else start();
    });
  }
  function confirmBox(text, opts) {
    opts = opts || {};
    return queuedBox(text, opts, [{ label: opts.cancel || "Cancel", value: "cancel" }, { label: opts.ok || "OK", value: "ok", kind: opts.danger ? "danger" : "primary" }]);
  }
  function alertBox(text, opts) {
    opts = opts || {};
    return queuedBox(text, opts, [{ label: opts.ok || "OK", value: "ok", kind: "primary" }]).then(function () { });
  }

  // ---- Forms and touch parts (kit revision 17), after the shared element specs: listbox, number field,
  // typed fields, password, one-time code, address, date range, sheet, carousel, reorder, swipe actions,
  // splitter, disclosure, toolbar overflow and breadcrumbs that fold. Each starts on its data-kit-* hook
  // (PARTS below); an aria-disabled control keeps its place and does nothing (the guard above); under
  // reduced motion they move at once.
  function reducedMotion() { return !!(window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches); }
  function emit(el, name, detail) { el.dispatchEvent(new CustomEvent("kit:" + name, { bubbles: true, detail: detail || {} })); }
  var kitUid = 0;
  function idOf(el, prefix) { if (!el.id) el.id = "kit-" + prefix + "-" + (++kitUid); return el.id; }
  function describedBy(el, id, add) {
    var ids = (el.getAttribute("aria-describedby") || "").split(/\s+/).filter(function (x) { return x && x !== id; });
    if (add) ids.push(id);
    if (ids.length) el.setAttribute("aria-describedby", ids.join(" ")); else el.removeAttribute("aria-describedby");
  }
  function readStore(key) { try { return localStorage.getItem(key); } catch (e) { return null; } }
  function writeStore(key, v) { try { localStorage.setItem(key, v); } catch (e) { /* not kept: private window or blocked storage */ } }
  function clampNum(v, lo, hi) { return Math.min(Math.max(v, lo), hi); }
  function nfc(s) { s = String(s == null ? "" : s); return s.normalize ? s.normalize("NFC") : s; }
  function hiddenInput(name, value) { var h = document.createElement("input"); h.type = "hidden"; h.name = name; h.value = value || ""; return h; }
  function rowWidth(el) { return el.getBoundingClientRect().width; }
  // Small line icons in the text colour, so these parts need no icons script.
  var ICONS = {
    eye: '<path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/>',
    "eye-off": '<path d="M6.6 3.7A6.6 6.6 0 0 1 8 3.5c4 0 6.5 4.5 6.5 4.5a12 12 0 0 1-1.7 2.3M9.4 9.5a2 2 0 0 1-2.9-2.8M4.2 4.9C2.5 6.1 1.5 8 1.5 8s2.5 4.5 6.5 4.5c1.2 0 2.3-.4 3.2-.9M2 2l12 12"/>',
    more: '<path d="M3.5 8h.01M8 8h.01M12.5 8h.01" stroke-width="2.4"/>'
  };
  function lineIcon(name) { return '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">' + ICONS[name] + "</svg>"; }

  // Listbox (rich rows; a plain choice stays a native <select>): <ul class="kit-listbox" role="listbox" data-kit-listbox
  // aria-label="Owner"> of <li class="kit-option" role="option" data-value="ana"><span class="kit-option__label">Ana Lima</span>
  // <span class="kit-option__meta">Design</span></li>; aria-multiselectable="true" for several. One Tab stop
  // (aria-activedescendant): arrows, Home, End and typed letters move; one choice follows the move, several toggle
  // with Space, Enter or a click (Shift+arrow adds, Ctrl+A takes all). An aria-disabled option keeps its place but is
  // never picked. In a kit-popover a pick closes it and writes the label into the button's [data-kit-listbox-value].
  // data-name="FIELD" sends the values with a form. kit:select with detail.value (the first) and detail.values.
  function optionLabel(o) {
    var l = o.querySelector(".kit-option__label");
    if (l) return l.textContent.trim();
    var t = Array.prototype.filter.call(o.childNodes, function (n) { return n.nodeType === 3; }).map(function (n) { return n.nodeValue; }).join("").trim();
    return t || o.textContent.trim();
  }
  function setupListbox(box) {
    if (box.kitListbox) return;
    box.kitListbox = true;
    var multi = box.getAttribute("aria-multiselectable") === "true", active = null, sent = [];
    var pop = box.closest(".kit-popover"), opener = pop && pop.id ? document.querySelector('[data-kit-popover="' + pop.id + '"]') : null;
    if (!box.getAttribute("role")) box.setAttribute("role", "listbox");
    if (!box.hasAttribute("tabindex")) box.tabIndex = 0;
    if (opener) opener.setAttribute("aria-haspopup", "listbox");
    function options() { return Array.prototype.slice.call(box.querySelectorAll('[role="option"]')); }
    function optionValue(o) { return o.getAttribute("data-value") || optionLabel(o); }
    function picked() { return options().filter(function (o) { return o.getAttribute("aria-selected") === "true"; }); }
    function activate(o) {
      if (!o) return;
      if (active) active.removeAttribute("data-active");
      active = o;
      o.setAttribute("data-active", "");
      box.setAttribute("aria-activedescendant", idOf(o, "option"));
      try { if (o.scrollIntoView) o.scrollIntoView({ block: "nearest" }); } catch (e) { /* an old engine */ }
    }
    function listSync(send) {
      var on = picked(), vals = on.map(optionValue), name = box.getAttribute("data-name");
      sent.forEach(function (h) { if (h.parentNode) h.parentNode.removeChild(h); });
      sent = name && box.parentNode ? vals.map(function (v) { var h = hiddenInput(name, v); h.kitFor = box; box.parentNode.insertBefore(h, box.nextSibling); return h; }) : [];
      var shown = opener && opener.querySelector("[data-kit-listbox-value]");
      if (shown) shown.textContent = on.length ? on.map(optionLabel).join(", ") : (shown.getAttribute("data-empty") || "");
      if (send) emit(box, "select", { value: vals[0] || "", values: vals });
    }
    function listPick(o, on) {
      if (!o || isOff(o)) return;
      if (multi) o.setAttribute("aria-selected", String(on === true ? true : o.getAttribute("aria-selected") !== "true"));
      else options().forEach(function (x) { x.setAttribute("aria-selected", String(x === o)); });
      activate(o);
      listSync(true);
      if (!multi && opener && opener.getAttribute("aria-expanded") === "true") { closePopovers(); opener.focus(); }
    }
    options().forEach(function (o) { if (!o.hasAttribute("aria-selected")) o.setAttribute("aria-selected", "false"); idOf(o, "option"); });
    box.addEventListener("focus", function () { if (!active || !box.contains(active)) activate(picked()[0] || options()[0]); });
    box.addEventListener("click", function (e) { var o = closestOf(e.target, '[role="option"]'); if (o && box.contains(o)) listPick(o); });
    box.addEventListener("keydown", function (e) {
      var list = options(), i = list.indexOf(active), k = e.key, to = null;
      if (!list.length) return;
      if (k === "ArrowDown") to = list[Math.min(i + 1, list.length - 1)];
      else if (k === "ArrowUp") to = list[Math.max(i - 1, 0)];
      else if (k === "Home") to = list[0];
      else if (k === "End") to = list[list.length - 1];
      else if (k === "Enter" || k === " ") { e.preventDefault(); listPick(active || list[0]); return; }
      else if (multi && (e.ctrlKey || e.metaKey) && (k === "a" || k === "A")) {
        e.preventDefault();
        var can = list.filter(function (o) { return !isOff(o); }), all = can.some(function (o) { return o.getAttribute("aria-selected") !== "true"; });
        can.forEach(function (o) { o.setAttribute("aria-selected", String(all)); });
        listSync(true);
        return;
      }
      else if (typeaheadKey(e)) to = typeahead(list, active, k, optionLabel);
      if (!to) return;
      e.preventDefault();
      activate(to);
      if (multi && e.shiftKey) listPick(to, true);
      else if (!multi && !opener) listPick(to);
    });
    listSync(false);
  }

  // Number field (never type="number"): <div class="kit-number"><button class="kit-number__step" type="button"
  // data-kit-nudge="-1" aria-label="Less">-</button><input class="kit-input" data-kit-number inputmode="decimal" min="0"
  // max="99" step="1" value="4" name="qty" aria-label="Quantity"><button class="kit-number__step" type="button"
  // data-kit-nudge="1" aria-label="More">+</button></div>. role="spinbutton" with aria-valuemin/max/now. Typing is a
  // draft; blur or Enter commits it: the page language's decimal comma or point, groups, a leading + and a unit typed
  // along are read, then the value shows formatted, kept within min and max (data-integer refuses a fraction,
  // data-snap rounds to the step). Text that is no number stays, with a message. Arrows step, PageUp/PageDown and
  // Shift+arrow take 10 steps (data-large-step), Home and End go to min and max. The step buttons are no Tab stops,
  // keep the focus in the field, repeat while held and turn aria-disabled at a bound. The wheel changes nothing
  // unless data-wheel, and then only while the field has focus. A named field sends the plain number ("1250.5").
  // data-valuetext="{value} percent" sets aria-valuetext. kit:change with detail.value (null when emptied).
  function numberSeps() {
    var out = { decimal: ".", group: "," };
    try { new Intl.NumberFormat(pageLang()).formatToParts(12345.6).forEach(function (p) { if (p.type === "decimal") out.decimal = p.value; if (p.type === "group") out.group = p.value; }); } catch (e) { /* the defaults */ }
    return out;
  }
  // Which of . and , is the decimal mark ("" for none): with both, the last one; one that repeats groups; the
  // page's own decimal mark is decimal; "1,250" in a page whose mark is "." groups.
  function decimalMark(s, decimal) {
    var dot = s.lastIndexOf("."), comma = s.lastIndexOf(",");
    if (dot >= 0 && comma >= 0) return dot > comma ? "." : ",";
    var mark = dot >= 0 ? "." : comma >= 0 ? "," : "";
    if (!mark || s.split(mark).length > 2) return "";
    if (mark === decimal) return mark;
    return /^\d{1,3}[.,]\d{3}$/.test(s) ? "" : mark;
  }
  // A number as people type it, as { neg, int, frac } digit strings; null when it is no number.
  function numberParts(text) {
    var s = nfc(text).replace(/[\uff10-\uff19]/g, function (c) { return String.fromCharCode(c.charCodeAt(0) - 0xfee0); })
      .replace(/[\s'\u2019\u00a0\u202f]/g, "").replace(/\u2212/g, "-").replace(/^\+/, "");
    s = s.replace(/^[$\u00a2-\u00a5\u20a0-\u20bf]+/, "").replace(/[^\d.,]+$/, "");   // a currency sign before it, a unit after it
    var neg = s.charAt(0) === "-";
    if (neg) s = s.slice(1).replace(/^[$\u00a2-\u00a5\u20a0-\u20bf]+/, "");
    if (!/^[\d.,]+$/.test(s) || !/\d/.test(s)) return null;
    var mark = decimalMark(s, numberSeps().decimal), at = mark ? s.lastIndexOf(mark) : -1;
    var whole = at < 0 ? s : s.slice(0, at), frac = at < 0 ? "" : s.slice(at + 1);
    if (/[.,]/.test(frac)) return null;
    return { neg: neg, int: whole.replace(/[.,]/g, "") || "0", frac: frac };
  }
  function parseNumber(text) { var p = numberParts(text); return p ? Number((p.neg ? "-" : "") + p.int + (p.frac ? "." + p.frac : "")) : NaN; }
  function stepDecimals(step) { var s = String(step), i = s.indexOf("."); return i < 0 ? 0 : s.length - i - 1; }
  function setupNumber(input) {
    if (input.kitNumber) return;
    input.kitNumber = true;
    var box = input.closest(".kit-number") || input.parentNode;
    var attr = function (name, fallback) { var v = parseFloat(input.getAttribute(name)); return isNaN(v) ? fallback : v; };
    var min = attr("min", -Infinity), max = attr("max", Infinity), step = attr("step", 1) || 1, large = attr("data-large-step", step * 10);
    var dec = stepDecimals(input.getAttribute("step") || "1"), value = null, sent = null, msg = null, held = null, repeated = false;
    input.setAttribute("role", "spinbutton");
    if (!input.getAttribute("inputmode")) input.setAttribute("inputmode", dec ? "decimal" : "numeric");
    if (!input.getAttribute("autocomplete")) input.setAttribute("autocomplete", "off");
    if (isFinite(min)) input.setAttribute("aria-valuemin", String(min));
    if (isFinite(max)) input.setAttribute("aria-valuemax", String(max));
    if (input.name) { sent = hiddenInput(input.name, ""); sent.kitFor = input; input.removeAttribute("name"); input.parentNode.insertBefore(sent, input.nextSibling); }
    var buttons = Array.prototype.slice.call(box.querySelectorAll("[data-kit-nudge]"));
    function shown(n) { return n === null ? "" : n.toLocaleString(pageLang(), { maximumFractionDigits: Math.max(dec, 10) }); }
    function showError(text) {
      if (!text && !msg) return;
      if (!msg) { msg = document.createElement("p"); msg.className = "kit-error-text"; idOf(msg, "error"); box.parentNode.insertBefore(msg, box.nextSibling); }
      msg.textContent = text;
      msg.hidden = !text;
      if (text) input.setAttribute("aria-invalid", "true"); else input.removeAttribute("aria-invalid");
      describedBy(input, msg.id, !!text);
      if (text) announce(text);
    }
    function set(n, send) {
      var before = value;
      value = n;
      input.value = shown(n);
      if (n === null) input.removeAttribute("aria-valuenow"); else input.setAttribute("aria-valuenow", String(n));
      var vt = input.getAttribute("data-valuetext");
      if (vt && n !== null) input.setAttribute("aria-valuetext", vt.replace("{value}", shown(n)));
      if (sent) sent.value = n === null ? "" : String(n);
      buttons.forEach(function (b) {
        var d = parseFloat(b.getAttribute("data-kit-nudge")) || 0, atBound = n !== null && (d < 0 ? n <= min : n >= max);
        if (atBound || isOff(input)) b.setAttribute("aria-disabled", "true"); else b.removeAttribute("aria-disabled");
      });
      showError("");
      if (send && before !== n) emit(input, "change", { value: n });
    }
    function commit() {
      var t = input.value.trim();
      if (!t) { if (input.required && value !== null) set(value, false); else set(null, true); return; }
      var n = parseNumber(t), mark = numberSeps().decimal;
      if (isNaN(n)) { showError("Use a number, like 12" + (dec ? " or 3" + mark + "5" : "") + "."); return; }
      if (input.hasAttribute("data-integer") && Math.round(n) !== n) { showError("Use a whole number, like 12."); return; }
      if (input.hasAttribute("data-snap")) { var base = isFinite(min) ? min : 0; n = Number((base + Math.round((n - base) / step) * step).toFixed(dec)); }
      set(clampNum(n, min, max), true);
    }
    function nudge(times, quiet) {
      if (isOff(input) || input.readOnly) return false;
      if (input.value !== shown(value)) commit();
      var from = value === null ? (isFinite(min) ? min : 0) : value;
      var n = clampNum(Number((from + times * step).toFixed(dec)), min, max);
      if (n === value) return false;
      set(n, !quiet);
      return true;
    }
    input.addEventListener("keydown", function (e) {
      if (e.isComposing || e.keyCode === 229) return;   // a key that composes text (IME) never steps
      var k = e.key, times = 0;
      if (k === "Enter") { commit(); return; }
      if (k === "ArrowUp" || k === "ArrowDown") times = (k === "ArrowUp" ? 1 : -1) * (e.shiftKey ? large / step : 1);
      else if (k === "PageUp" || k === "PageDown") times = (k === "PageUp" ? 1 : -1) * large / step;
      else if ((k === "Home" && isFinite(min)) || (k === "End" && isFinite(max))) {
        e.preventDefault();
        if (!isOff(input) && !input.readOnly) set(k === "Home" ? min : max, true);
        return;
      }
      if (!times) return;
      e.preventDefault();
      nudge(times);
    });
    input.addEventListener("blur", commit);
    input.addEventListener("wheel", function (e) {
      if (!input.hasAttribute("data-wheel") || document.activeElement !== input) return;   // the wheel scrolls the page
      var d = e.deltaY < 0 ? 1 : e.deltaY > 0 ? -1 : 0;
      if (d && nudge(d)) e.preventDefault();
    }, { passive: false });
    buttons.forEach(function (b) {
      var d = parseFloat(b.getAttribute("data-kit-nudge")) || 0;
      b.tabIndex = -1;
      if (!b.getAttribute("aria-label")) b.setAttribute("aria-label", d < 0 ? "Less" : "More");
      if (input.id) b.setAttribute("aria-controls", input.id);
      b.addEventListener("mousedown", function (e) { e.preventDefault(); });   // the focus stays in the field
      b.addEventListener("pointerdown", function (e) {
        if (e.button !== 0 || isOff(b)) return;
        repeated = false;
        clearTimeout(held);
        var again = function (wait) { held = setTimeout(function () { repeated = true; if (nudge(d, true)) again(80); }, wait); };
        again(500);
      });
      ["pointerup", "pointerleave", "pointercancel"].forEach(function (n) {
        b.addEventListener(n, function () { clearTimeout(held); held = null; if (repeated && n !== "pointerup") { repeated = false; emit(input, "change", { value: value }); } });
      });
      b.addEventListener("click", function () {
        if (repeated) { repeated = false; emit(input, "change", { value: value }); return; }   // held: one change on release
        nudge(d);
      });
    });
    var start = input.value.trim(), first = start ? parseNumber(start) : NaN;
    set(isNaN(first) ? null : clampNum(first, min, max), false);
    if (start && isNaN(first)) input.value = start;
  }

  // Typed fields: data-kit-field="name|text|email|phone|postcode|iban|card|expiry|card-code|code|url|amount|password|
  // new-password" on a kit-input with its type, inputmode and autocomplete (phone, postcode, card and codes are text
  // or tel, never type="number"). Shape checks only, which help the person (the server checks again): blur shows the
  // clean form (+31 20 123 4567, NL74 EXMP 0123 4567 89, 1234 AB) and the form sends the stored one (+31201234567);
  // a password is never changed. Errors show on submit (put novalidate on the form): the submit stops and the first
  // failing field takes focus, a closed section around it opens; from then on blur checks again and typing clears a
  // fixed error. The message goes in a kit-error-text under the field (aria-invalid, aria-describedby). An email
  // domain one typo from a common one gets "Did you mean ...?" with a button. Options: data-kit-country="ID" (the
  // country select: its value for a postcode, its option's data-calling-code for a phone), data-calling-code="31",
  // data-kit-card="ID" (for card-code), data-length (code), data-decimals and data-negative (amount), minlength
  // (new-password, default 8), data-max (name, text). KitUI.check(kind, text, options) runs a check from code and
  // gives { value, display, ok, message }. kit:check with detail.kind, value and ok after each check.
  function fieldResult(value, display, ok, message) { return { value: value, display: display, ok: ok, message: ok ? "" : message }; }
  function fieldFail(text, message) { return fieldResult(text, text, false, message); }
  function graphemes(s) { try { return Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(s)).length; } catch (e) { return Array.from(s).length; } }
  function tidyText(s) { return nfc(s).trim().replace(/\s+/g, " "); }
  function digitsOf(s) { return nfc(s).replace(/\D/g, ""); }
  function pad2(n) { return ("0" + n).slice(-2); }
  function groupsOf(s, size) { var out = []; for (var i = 0; i < s.length; i += size) out.push(s.slice(i, i + size)); return out.join(" "); }
  function checkLength(v, max, empty) {
    if (!v) return fieldFail(v, empty);
    var n = graphemes(v);
    return n > max ? fieldFail(v, "Use at most " + max + " characters; this has " + n + ".") : fieldResult(v, v, true);
  }
  // Email: one @, something before it, a dot in the domain (lowercased). A common domain one typo away is offered.
  var MAIL_DOMAINS = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "icloud.com", "me.com", "aol.com", "proton.me", "protonmail.com", "gmx.de", "gmx.net", "web.de"];
  function editDistance(a, b) {
    var d = [], i, j;
    for (i = 0; i <= a.length; i++) d.push([i]);
    for (j = 1; j <= b.length; j++) d[0][j] = j;
    for (i = 1; i <= a.length; i++) {
      for (j = 1; j <= b.length; j++) {
        d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
        if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);   // two letters swapped
      }
    }
    return d[a.length][b.length];
  }
  function domainHint(domain) {
    if (MAIL_DOMAINS.indexOf(domain) >= 0) return "";
    return MAIL_DOMAINS.filter(function (m) { var n = editDistance(domain, m); return n === 1 || (n === 2 && m.length >= 10); })[0] || "";
  }
  function checkEmail(text) {
    var v = nfc(text).trim(), ex = "like ana@studio.example";
    if (!v) return fieldFail(v, "Enter an email address, " + ex + ".");
    if (/\s/.test(v)) return fieldFail(v, "Remove the space: an email address has none, " + ex + ".");
    var parts = v.split("@");
    if (parts.length !== 2) return fieldFail(v, parts.length < 2 ? "Add the @ and the domain, " + ex + "." : "Use one @ only, " + ex + ".");
    var domain = parts[1].toLowerCase();
    if (!parts[0]) return fieldFail(v, "Add the part before the @, " + ex + ".");
    if (!/^[^.]+(\.[^.]+)+$/.test(domain)) return fieldFail(v, "Add the domain after the @, with a dot in it, " + ex + ".");
    var out = parts[0] + "@" + domain, r = fieldResult(out, out, true), hint = domainHint(domain);
    r.suggestion = hint ? parts[0] + "@" + hint : "";
    return r;
  }
  // Phone: spaces, dashes, dots, slashes, brackets and + or 00 accepted; stored as +DIGITS, 7 to 15 digits.
  var TWO_DIGIT_CODES = " 20 27 30 31 32 33 34 36 39 40 41 43 44 45 46 47 48 49 51 52 53 54 55 56 57 58 60 61 62 63 64 65 66 81 82 84 86 90 91 92 93 94 95 98 ";
  function callingCode(d) { return d.charAt(0) === "1" || d.charAt(0) === "7" ? d.charAt(0) : TWO_DIGIT_CODES.indexOf(" " + d.slice(0, 2) + " ") >= 0 ? d.slice(0, 2) : d.slice(0, 3); }
  function checkPhone(text, o) {
    var raw = nfc(text).trim(), ex = "like +31 20 123 4567";
    if (!raw) return fieldFail(raw, "Enter a phone number, " + ex + ".");
    var compact = raw.replace(/\(0\)/g, "").replace(/[\s().\-\/]/g, "");
    if (!/^\+?\d+$/.test(compact)) return fieldFail(raw, "Use digits, spaces or dashes only, " + ex + ".");
    var digits = null, cc = String(o.callingCode || "").replace(/^(\+|00)/, "");
    if (compact.charAt(0) === "+") digits = compact.slice(1);
    else if (compact.slice(0, 2) === "00") digits = compact.slice(2);
    else if (/^\d{1,3}$/.test(cc)) digits = cc + (cc === "39" ? compact : compact.replace(/^0/, ""));   // Italy keeps its leading 0
    if (!digits) return fieldFail(raw, "Add the country code, " + ex + ".");
    var code = callingCode(digits), national = digits.slice(code.length);
    if (national.length < 7 || digits.length > 15) return fieldFail(raw, "A phone number has 7 to 15 digits after the country code, " + ex + ".");
    var groups = [], i = 0;
    for (; national.length - i > 4; i += 3) groups.push(national.slice(i, i + 3));
    groups.push(national.slice(i));
    return fieldResult("+" + digits, "+" + code + " " + groups.join(" "), true);
  }
  // Web address: https:// added when missing; only http and https with a host that has a dot.
  function checkUrl(text) {
    var raw = nfc(text).trim(), ex = "like studio.example/menu", url = null;
    if (!raw) return fieldFail(raw, "Enter a web address, " + ex + ".");
    try { url = new URL(/^[a-z][a-z\d+.\-]*:\/\//i.test(raw) ? raw : "https://" + raw.replace(/^\/+/, "")); } catch (e) { url = null; }
    if (!url) return fieldFail(raw, "This is not a web address that can be opened, " + ex + ".");
    if (!/^https?:$/.test(url.protocol)) return fieldFail(raw, "Use an address that starts with https://, " + ex + ".");
    if (url.hostname.indexOf(".") < 0 && url.hostname !== "localhost") return fieldFail(raw, "Add the domain with a dot in it, " + ex + ".");
    var bare = url.pathname === "/" && !url.search && !url.hash && raw.slice(-1) !== "/";
    return fieldResult(url.href, bare ? url.href.slice(0, -1) : url.href, true);
  }
  // Amount: the page language's decimal mark, groups and a currency sign accepted; stored as a decimal string
  // ("1250.50", never a float), shown in the page's form ("1.250,50").
  function checkAmount(text, o) {
    var seps = numberSeps(), decimals = o.decimals === undefined ? 2 : o.decimals, raw = nfc(text).trim();
    var ex = "like 1" + seps.group + "250" + (decimals ? seps.decimal + "50" : "");
    if (!raw) return fieldFail(raw, "Enter an amount, " + ex + ".");
    var p = numberParts(raw);
    if (!p) return fieldFail(raw, "Use digits with one decimal mark, " + ex + ".");
    if (p.neg && !o.negative) return fieldFail(raw, "Enter an amount of 0 or more, " + ex + ".");
    if (p.frac.length > decimals) return fieldFail(raw, decimals ? "Use at most " + decimals + " decimals, " + ex + "." : "Use a whole number, like 1" + seps.group + "250.");
    var whole = p.int.replace(/^0+(?=\d)/, ""), frac = decimals ? (p.frac + "000000000000").slice(0, decimals) : "";
    var sign = p.neg && /[1-9]/.test(whole + frac) ? "-" : "";
    var grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, seps.group);
    return fieldResult(sign + whole + (frac ? "." + frac : ""), sign + grouped + (frac ? seps.decimal + frac : ""), true);
  }
  function checkCode(text, o) {
    var v = digitsOf(text), n = o.length || 6, ex = "like " + "123456789123456789".slice(0, n);
    if (!v) return fieldFail(v, "Enter the " + n + "-digit code from the message, " + ex + ".");
    return v.length === n ? fieldResult(v, v, true) : fieldFail(v, "The code has " + n + " digits; this has " + v.length + ", " + ex + ".");
  }
  // A password is never trimmed or changed; a new one needs a length (counted as a person counts letters).
  function checkPassword(text, min) {
    var v = String(text);
    if (!v) return fieldFail(v, min ? "Enter a password of at least " + min + " characters." : "Enter your password.");
    var n = graphemes(v);
    return n < min ? fieldFail(v, "Use at least " + min + " characters; this has " + n + ". A few unrelated words are easy to remember.") : fieldResult(v, v, true);
  }
  // IBAN: the length per country and the mod-97 check; stored uppercase without spaces, shown in groups of four.
  var IBAN_LENGTHS = { AD: 24, AE: 23, AL: 28, AT: 20, AZ: 28, BA: 20, BE: 16, BG: 22, BH: 22, BR: 29, BY: 28, CH: 21, CR: 22, CY: 28, CZ: 24, DE: 22, DK: 18, DO: 28, EE: 20, EG: 29, ES: 24, FI: 18, FO: 18, FR: 27, GB: 22, GE: 22, GI: 23, GL: 18,
    GR: 27, GT: 28, HR: 21, HU: 28, IE: 22, IL: 23, IQ: 23, IS: 26, IT: 27, JO: 30, KW: 30, KZ: 20, LB: 28, LC: 32, LI: 21, LT: 20, LU: 20, LV: 21, MC: 27, MD: 24, ME: 22, MK: 19, MR: 27, MT: 31, MU: 30, NL: 18, NO: 15, PK: 24,
    PL: 28, PS: 29, PT: 25, QA: 29, RO: 24, RS: 22, SA: 24, SC: 31, SE: 24, SI: 19, SK: 24, SM: 27, ST: 25, SV: 28, TL: 23, TN: 24, TR: 26, UA: 29, VA: 22, VG: 24, XK: 20 };
  function ibanRemainder(chars) {
    var r = 0;
    for (var i = 0; i < chars.length; i++) { var c = chars.charAt(i), n = c >= "A" ? c.charCodeAt(0) - 55 : Number(c); r = n > 9 ? (r * 100 + n) % 97 : (r * 10 + n) % 97; }
    return r;
  }
  function checkIban(text) {
    var v = nfc(text).toUpperCase().replace(/^IBAN:?/, "").replace(/[\s\-]/g, ""), ex = "like NL74 EXMP 0123 4567 89";
    if (!v) return fieldFail(v, "Enter an IBAN, " + ex + ".");
    if (!/^[A-Z]{2}\d{2}[A-Z\d]+$/.test(v)) return fieldFail(v, "An IBAN starts with two letters and two digits, then letters and digits, " + ex + ".");
    var cc = v.slice(0, 2), len = IBAN_LENGTHS[cc];
    if (!len) return fieldFail(v, cc + " is not a country code that uses IBANs; check the first two letters, " + ex + ".");
    if (v.length !== len) return fieldFail(v, "An IBAN from " + cc + " has " + len + " characters; this has " + v.length + ".");
    if (ibanRemainder(v.slice(4) + v.slice(0, 4)) !== 1) return fieldFail(v, "This IBAN has a typo: check each character against the bank details.");
    return fieldResult(v, groupsOf(v, 4), true);
  }
  // Card number: 12 to 19 digits and the Luhn sum; the brand from the first digits; shown grouped as on the card.
  var CARD_BRANDS = [["amex", /^3[47]/], ["diners", /^3(0[0-5]|[689])/], ["jcb", /^35(2[89]|[3-8]\d)/], ["mastercard", /^(5[1-5]|2(22[1-9]|2[3-9]\d|[3-6]\d\d|7[01]\d|720))/],
    ["visa", /^4/], ["discover", /^(6011|65|64[4-9])/], ["unionpay", /^62/], ["maestro", /^(50|5[6-8]|6\d)/]];
  function cardBrand(d) { return (CARD_BRANDS.filter(function (b) { return b[1].test(d); })[0] || [""])[0]; }
  function luhn(d) {
    var sum = 0;
    for (var i = 0; i < d.length; i++) { var n = Number(d.charAt(d.length - 1 - i)); if (i % 2) n = n * 2 > 9 ? n * 2 - 9 : n * 2; sum += n; }
    return d.length > 0 && sum % 10 === 0;
  }
  function checkCard(text) {
    var raw = nfc(text).trim(), d = digitsOf(raw), brand = cardBrand(d), ex = "like 4000 1234 5678 9010", r;
    if (!raw) r = fieldFail(raw, "Enter the card number from the front of the card, " + ex + ".");
    else if (/[^\d\s\-]/.test(raw)) r = fieldFail(raw, "Use digits only, " + ex + ".");
    else if (d.length < 12 || d.length > 19) r = fieldFail(raw, "A card number has 12 to 19 digits, " + ex + "; this has " + d.length + ".");
    else if (!luhn(d)) r = fieldFail(raw, "This card number has a typo: check the digits against the card.");
    else {
      var sizes = brand === "amex" ? [4, 6, 5] : brand === "diners" && d.length === 14 ? [4, 6, 4] : null, at = 0;
      r = fieldResult(d, sizes ? sizes.map(function (n) { var s = d.slice(at, at + n); at += n; return s; }).filter(Boolean).join(" ") + d.slice(at) : groupsOf(d, 4), true);
    }
    r.brand = brand;
    return r;
  }
  // Expiry: MM/YY, MMYY, MM-YY and MM/YYYY accepted; stored YYYY-MM, shown MM/YY; not in the past.
  function checkExpiry(text) {
    var raw = nfc(text).trim(), ex = "like 08/29", now = new Date();
    if (!raw) return fieldFail(raw, "Enter the expiry date from the card, " + ex + ".");
    var m = /^(\d{1,2})\s*[\/.\-\s]?\s*(\d{2}|\d{4})$/.exec(raw);
    if (!m) return fieldFail(raw, "Enter the month and the year, " + ex + ".");
    var month = Number(m[1]), year = m[2].length === 2 ? 2000 + Number(m[2]) : Number(m[2]);
    if (month < 1 || month > 12) return fieldFail(raw, "The month is 01 to 12, " + ex + ".");
    var value = year + "-" + pad2(month);
    if (value < now.getFullYear() + "-" + pad2(now.getMonth() + 1)) return fieldFail(raw, "This date has passed: use the expiry date of a card that is still valid.");
    return fieldResult(value, pad2(month) + "/" + String(year).slice(-2), true);
  }
  function checkCardCode(text, o) {
    var v = digitsOf(text), amex = o.brand === "amex", n = amex ? 4 : 3;
    return v.length === n ? fieldResult(v, v, true) : fieldFail(v, "Enter the " + n + "-digit security code on the " + (amex ? "front" : "back") + " of the card, like " + "1234".slice(0, n) + ".");
  }
  // Postcodes: the country's format from a table (a loose check for a country not in it); none where the post
  // uses none. The format says nothing about whether an address exists.
  var PC4 = { re: /^\d{4}$/, ex: "1234" }, PC5 = { re: /^\d{5}$/, ex: "12345" }, PC6 = { re: /^\d{6}$/, ex: "123456" }, PC5S = { re: /^\d{5}$/, at: 3, ex: "123 45" };
  var POSTCODES = {
    NL: { re: /^[1-9]\d{3}[A-Z]{2}$/, at: 4, ex: "1234 AB" }, BE: { re: /^[1-9]\d{3}$/, ex: "1234" },
    GB: { re: /^([A-Z]{1,2}\d[A-Z\d]?|GIR)\d[A-Z]{2}$/, at: -3, ex: "AB12 3CD" }, IE: { re: /^([AC-FHKNPRTV-Y]\d{2}|D6W)[\dAC-FHKNPRTV-Y]{4}$/, at: 3, ex: "A65 F4E2" },
    US: { re: /^\d{5}(\d{4})?$/, at: 5, sep: "-", ex: "12345" }, CA: { re: /^[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z]\d[ABCEGHJ-NPRSTV-Z]\d$/, at: 3, ex: "A1B 2C3" },
    PL: { re: /^\d{5}$/, at: 2, sep: "-", ex: "12-345" }, PT: { re: /^\d{7}$/, at: 4, sep: "-", ex: "1234-567" }, JP: { re: /^\d{7}$/, at: 3, sep: "-", ex: "123-4567" },
    BR: { re: /^\d{8}$/, at: 5, sep: "-", ex: "12345-678" }, IL: { re: /^\d{7}$/, ex: "1234567" }, IS: { re: /^\d{3}$/, ex: "123" }, LV: { re: /^\d{4}$/, prefix: "LV-", ex: "LV-1234" },
    MT: { re: /^[A-Z]{3}\d{4}$/, at: 3, ex: "ABC 1234" }
  };
  "LU AT CH DK NO HU SI BG CY AU NZ ZA PH".split(" ").forEach(function (c) { POSTCODES[c] = PC4; });
  "DE FR ES IT FI EE HR LT MX TR MY TH UA KR".split(" ").forEach(function (c) { POSTCODES[c] = PC5; });
  "GR SE CZ SK".split(" ").forEach(function (c) { POSTCODES[c] = PC5S; });
  "IN RU CN SG RO".split(" ").forEach(function (c) { POSTCODES[c] = PC6; });
  var NO_POSTCODE = " AE AG AO AW BS BZ CW DJ FJ GD HK KI MO QA TO TV UG VU ZW ";
  var REGIONS = { US: ["State", true], CA: ["Province or territory", true], AU: ["State or territory", true], BR: ["State", true], MX: ["State", true], IN: ["State", true],
    JP: ["Prefecture", true], CN: ["Province", true], IT: ["Province", false], ES: ["Province", false], IE: ["County", false] };
  function addressFor(country) {
    var cc = String(country || "").trim().toUpperCase(), rule = POSTCODES[cc], r = REGIONS[cc];
    return { postcode: NO_POSTCODE.indexOf(" " + cc + " ") < 0, postcodeLabel: { US: "ZIP code", IE: "Eircode" }[cc] || "Postcode",
      inputmode: rule && !/[A-Z]/.test(rule.ex) ? "numeric" : "text", example: rule ? rule.ex : "", region: r ? { label: r[0], required: r[1] } : null };
  }
  function checkPostcode(text, o) {
    var cc = String(o.country || "").trim().toUpperCase(), shape = addressFor(cc), rule = POSTCODES[cc];
    if (!shape.postcode) return fieldResult("", "", true);
    var raw = nfc(text).trim().replace(/\s+/g, " ").toUpperCase();
    if (!raw) return fieldFail(raw, "Enter the " + shape.postcodeLabel.toLowerCase() + ", like " + (shape.example || "1234 AB") + ".");
    if (!rule) return /^[A-Z\d][A-Z\d \-]{1,9}$/.test(raw) ? fieldResult(raw, raw, true) : fieldFail(raw, "Use letters, digits, spaces or dashes, up to 10, like 1234 AB.");
    var tries = [raw, raw.replace(/^[A-Z]{1,2}-\s*/, "")].map(function (s) { return s.replace(/[\s\-]/g, ""); });
    tries.push(tries[0].indexOf(cc) === 0 ? tries[0].slice(cc.length) : "");
    var c = tries.filter(function (t) { return t && rule.re.test(t); })[0];
    var place = cc;
    try { place = new Intl.DisplayNames(["en"], { type: "region" }).of(cc) || cc; } catch (e) { /* the code */ }
    if (!c) return fieldFail(raw, shape.postcodeLabel + "s in " + place + " look like " + rule.ex + ".");
    var i = rule.at < 0 ? c.length + rule.at : rule.at, out = (rule.prefix || "") + (i > 0 && i < c.length ? c.slice(0, i) + (rule.sep || " ") + c.slice(i) : c);
    return fieldResult(out, out, true);
  }
  var FIELD_CHECKS = {
    name: function (v, o) { return checkLength(tidyText(v), o.max || 300, "Enter a name, like Ana Lima."); },
    text: function (v, o) { return checkLength(o.multiline ? nfc(v).trim() : tidyText(v), o.max || 1000, "Fill in this field."); },
    email: checkEmail, phone: checkPhone, postcode: checkPostcode, iban: checkIban, card: checkCard, expiry: checkExpiry, "card-code": checkCardCode,
    code: checkCode, url: checkUrl, amount: checkAmount,
    password: function (v) { return checkPassword(v, 0); }, "new-password": function (v, o) { return checkPassword(v, o.min || 8); }
  };
  function checkField(kind, text, opts) { var f = FIELD_CHECKS[kind]; return f ? f(String(text == null ? "" : text), opts || {}) : null; }
  var KEEP_TYPED = { password: 1, "new-password": 1 };
  function fieldOpts(el) {
    var byId = function (id) { return id ? document.getElementById(id) : null; };
    var block = el.closest("[data-kit-address]"), country = byId(el.getAttribute("data-kit-country")) || (block ? block.querySelector('[autocomplete~="country"]') : null);
    var opt = country && country.options ? country.options[country.selectedIndex] : null, card = byId(el.getAttribute("data-kit-card"));
    var num = function (a) { var v = parseFloat(el.getAttribute(a)); return isNaN(v) ? undefined : v; };
    return { country: country ? country.value : (el.getAttribute("data-country") || ""), callingCode: el.getAttribute("data-calling-code") || (opt && opt.getAttribute("data-calling-code")) || "",
      brand: card ? checkCard(card.value).brand : "", length: num("data-length"), decimals: num("data-decimals"), negative: el.hasAttribute("data-negative"),
      min: num("minlength"), max: num("data-max"), multiline: el.localName === "textarea" };
  }
  // A field in a closed section is still the form's: hidden="until-found" (a closed disclosure the
  // browser's find can reach) does not skip it; any other hidden ancestor does.
  function fieldSkipped(el) { return !!el.closest('[hidden]:not([hidden="until-found"])') || isOff(el) || el.readOnly; }
  function fieldEval(el) {
    var kind = el.getAttribute("data-kit-field");
    if (!FIELD_CHECKS[kind]) return null;
    if (!String(el.value || "").trim() && !el.required) return { value: "", display: "", ok: true, message: "", empty: true };
    return checkField(kind, el.value, fieldOpts(el));
  }
  function fieldNote(el, key, cls) {
    var n = el[key] && document.getElementById(el[key]);
    if (n) return n;
    n = document.createElement("p");
    n.className = cls;
    n.hidden = true;
    el[key] = idOf(n, "note");
    (el.closest(".kit-field") || el.parentNode).appendChild(n);
    return n;
  }
  function fieldShow(el, r) {
    var own = el.getAttribute("aria-errormessage"), m = (own && document.getElementById(own)) || fieldNote(el, "kitErrorId", "kit-error-text");
    if (r.ok) el.removeAttribute("aria-invalid"); else el.setAttribute("aria-invalid", "true");
    describedBy(el, m.id, !r.ok);
    m.hidden = r.ok;
    m.textContent = r.ok ? "" : r.message;
  }
  // "Did you mean ana@gmail.com?" with a button that takes it: offered, never forced.
  function fieldHint(el, r) {
    var h = el.kitHintId && document.getElementById(el.kitHintId);
    if (!r.suggestion) { if (h) { h.hidden = true; describedBy(el, h.id, false); } return; }
    h = fieldNote(el, "kitHintId", "kit-help");
    var b = document.createElement("button");
    b.type = "button";
    b.className = "kit-link";
    b.textContent = r.suggestion;
    b.addEventListener("click", function () { el.value = r.suggestion; fieldCommit(el); el.focus(); });
    h.textContent = "Did you mean ";
    h.appendChild(b);
    h.appendChild(document.createTextNode("?"));
    h.hidden = false;
    describedBy(el, h.id, true);
  }
  function fieldCommit(el, force) {
    if (fieldSkipped(el)) return null;
    var r = fieldEval(el), kind = el.getAttribute("data-kit-field");
    if (!r) return null;
    if (r.ok && !r.empty && !KEEP_TYPED[kind] && el.value !== r.display) el.value = r.display;
    if (force || (el.form && el.form.kitChecked) || el.getAttribute("aria-invalid") === "true") fieldShow(el, r);
    if (kind === "email") fieldHint(el, r);
    emit(el, "check", { kind: kind, value: r.value, ok: r.ok });
    return r;
  }
  function isTypedField(el) { return !!el && el.nodeType === 1 && el.hasAttribute("data-kit-field"); }
  document.addEventListener("focusout", function (e) { if (isTypedField(e.target)) safe(fieldCommit, e.target); });
  document.addEventListener("input", function (e) {
    var el = e.target;
    if (!isTypedField(el) || el.getAttribute("aria-invalid") !== "true") return;
    var r = fieldEval(el);
    if (r && r.ok) fieldShow(el, r);   // typing clears a fixed error, never shows a new one
  });
  document.addEventListener("submit", function (e) {
    var form = e.target;
    if (!form || !form.querySelectorAll) return;
    Array.prototype.forEach.call(form.querySelectorAll("[data-kit-password]"), function (g) { if (g.kitReveal) g.kitReveal(false); });   // the value hidden again
    var fields = Array.prototype.filter.call(form.querySelectorAll("[data-kit-field]"), function (el) { return !fieldSkipped(el); });
    if (!fields.length) return;
    form.kitChecked = true;
    var bad = fields.filter(function (el) { var r = fieldCommit(el, true); return r && !r.ok; });
    if (!bad.length) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    openAround(bad[0]);
    bad[0].focus();
  }, true);
  document.addEventListener("formdata", function (e) {
    var form = e.target, data = e.formData;
    if (!data || !form || !form.querySelectorAll) return;
    Array.prototype.forEach.call(form.querySelectorAll("[data-kit-field]"), function (el) {
      if (!el.name || KEEP_TYPED[el.getAttribute("data-kit-field")] || fieldSkipped(el)) return;
      var r = fieldEval(el);
      if (r && r.ok && !r.empty) data.set(el.name, r.value);   // the stored form, not the grouped display
    });
  }, true);

  // Password: <div class="kit-input-group kit-password" data-kit-password><input class="kit-input" id="pw" type="password"
  // autocomplete="current-password" data-kit-field="password"></div> (new-password with minlength="12" on a sign-up).
  // The reveal button is added when missing: an icon button "Show password" with aria-pressed, inside the field. It
  // keeps the focus, caret and selection where they were, and the value is hidden again on submit, so a new password
  // needs no confirm field. A note shows while Caps Lock is on; with minlength and no description "At least N
  // characters." is added before typing. For password managers: autocomplete set when missing or off, a maxlength under
  // 64 removed, no spelling check. The value is never trimmed or changed.
  function setupPassword(group) {
    var input = group.querySelector("input");
    if (group.kitPassword || !input) return;
    group.kitPassword = true;
    var auto = (input.getAttribute("autocomplete") || "").toLowerCase(), isNew = input.hasAttribute("minlength") || input.getAttribute("data-kit-field") === "new-password";
    if (!auto || auto === "off") input.setAttribute("autocomplete", isNew ? "new-password" : "current-password");
    var most = input.getAttribute("maxlength");
    if (most !== null && Number(most) < 64) input.removeAttribute("maxlength");
    input.setAttribute("spellcheck", "false");
    input.setAttribute("autocapitalize", "off");
    input.setAttribute("autocorrect", "off");
    var btn = group.querySelector("[data-kit-reveal]");
    if (!btn) {
      btn = document.createElement("button");
      btn.type = "button";
      btn.className = "kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm kit-password__reveal";
      btn.setAttribute("data-kit-reveal", "");
      btn.innerHTML = lineIcon("eye");   // injection: the kit's own icon markup, no outside text
      group.appendChild(btn);
    }
    btn.setAttribute("aria-label", "Show password");
    btn.setAttribute("aria-pressed", "false");
    if (input.id) btn.setAttribute("aria-controls", input.id);
    if (isOff(input)) btn.setAttribute("aria-disabled", "true");
    var field = group.closest(".kit-field") || group.parentNode, caps = document.createElement("p");
    caps.className = "kit-help";
    caps.setAttribute("role", "status");
    caps.textContent = "Caps Lock is on.";
    caps.hidden = true;
    idOf(caps, "caps");
    field.appendChild(caps);
    var least = Number(input.getAttribute("minlength")) || 0;
    if (least && !input.getAttribute("aria-describedby")) {
      var help = document.createElement("p");
      help.className = "kit-help";
      help.textContent = "At least " + least + " characters. A few unrelated words are easy to remember.";
      group.parentNode.insertBefore(help, group.nextSibling);
      describedBy(input, idOf(help, "help"), true);
    }
    group.kitReveal = function (show) {
      var focused = document.activeElement === input, a = input.selectionStart, b = input.selectionEnd;
      input.type = show ? "text" : "password";
      btn.setAttribute("aria-pressed", String(!!show));
      if (!btn.querySelector("[data-kit-icon]")) btn.innerHTML = lineIcon(show ? "eye-off" : "eye");   // injection: the kit's own icon markup
      if (focused) { input.focus(); try { input.setSelectionRange(a, b); } catch (e) { /* no caret here */ } }
    };
    btn.addEventListener("mousedown", function (e) { if (document.activeElement === input) e.preventDefault(); });   // the caret stays
    btn.addEventListener("click", function () { if (!isOff(input)) group.kitReveal(btn.getAttribute("aria-pressed") !== "true"); });
    var capsOn = function (e) { if (!e.getModifierState) return; var on = e.getModifierState("CapsLock"); caps.hidden = !on; describedBy(input, caps.id, on); };
    input.addEventListener("keydown", capsOn);
    input.addEventListener("keyup", capsOn);
    input.addEventListener("blur", function () { caps.hidden = true; describedBy(input, caps.id, false); });
  }

  // One-time code in boxes (one data-kit-field="code" field is the default and autofills best): <div class="kit-otp"
  // data-kit-otp data-name="code" role="group" aria-label="Code from the text message"> with one
  // <input class="kit-input kit-otp__box"> per digit. A digit moves on to the next box, Backspace in an empty box goes
  // back, Left and Right move; a pasted or autofilled code is spread over the boxes from there, never cut off. Boxes are
  // named "Digit 1 of 6" when unnamed. The digits go into a hidden input named data-name. kit:code with detail.value
  // and detail.complete.
  function setupOtp(group) {
    if (group.kitOtp) return;
    group.kitOtp = true;
    var boxes = function () { return Array.prototype.slice.call(group.querySelectorAll("input:not([type=hidden])")); };
    var name = group.getAttribute("data-name"), sent = name ? group.appendChild(hiddenInput(name, "")) : null, list = boxes();
    list.forEach(function (b, i) {
      if (!b.getAttribute("aria-label") && !b.getAttribute("aria-labelledby")) b.setAttribute("aria-label", "Digit " + (i + 1) + " of " + list.length);
      b.setAttribute("inputmode", "numeric");
      b.setAttribute("autocomplete", i === 0 ? "one-time-code" : "off");
      b.removeAttribute("maxlength");   // a maxlength would cut a pasted code
    });
    function otpSync() {
      var all = boxes(), v = all.map(function (b) { return b.value; }).join("");
      if (sent) sent.value = v;
      emit(group, "code", { value: v, complete: v.length === all.length });
    }
    function fill(digits, at) {
      var all = boxes(), n = Math.min(digits.length, all.length - at);
      for (var k = 0; k < n; k++) all[at + k].value = digits.charAt(k);
      var next = all[Math.min(at + Math.max(n, 1), all.length - 1)];
      if (n && next) next.focus();
      otpSync();
    }
    group.addEventListener("input", function (e) {
      var all = boxes(), i = all.indexOf(e.target);
      if (i < 0) return;
      var d = digitsOf(e.target.value);
      if (d.length > 1) { fill(d, i); return; }
      e.target.value = d;
      if (d && all[i + 1]) all[i + 1].focus();
      otpSync();
    });
    group.addEventListener("keydown", function (e) {
      var all = boxes(), i = all.indexOf(e.target), to = null;
      if (i < 0 || isOff(e.target)) return;
      if (e.key === "Backspace") to = !e.target.value && i > 0 ? all[i - 1] : null;
      else if (e.key === "ArrowLeft") to = all[i - 1] || null;
      else if (e.key === "ArrowRight") to = all[i + 1] || null;
      if (!to) return;
      e.preventDefault();
      if (e.key === "Backspace") { to.value = ""; otpSync(); }
      to.focus();
    });
  }

  // Address, country first: <fieldset class="kit-fieldset" data-kit-address> with a country select (autocomplete="country",
  // ISO codes as values), then street, city, a region field (autocomplete="address-level1") and a postcode field
  // (autocomplete="postal-code" data-kit-field="postcode"), each in a kit-field with a label. The country decides the
  // rest: the postcode field shows only where the post uses postcodes, labelled for it (ZIP code, Eircode) with an
  // invented example; the region field only where the country has one, required where its post needs it and else
  // marked (optional). A hidden field sends nothing. A postcode already typed is checked again. kit:address with
  // detail.country.
  function addressBox(input) { return input ? input.closest(".kit-field") || input.parentNode : null; }
  function addressLabel(input) { return input && input.id ? document.querySelector('label[for="' + input.id + '"]') : null; }
  function addressShow(input, show, required) {
    var box = addressBox(input);
    if (!box) return;
    box.hidden = !show;
    if (!show && input.name) { input.kitName = input.name; input.removeAttribute("name"); }
    if (show && !input.name && input.kitName) input.setAttribute("name", input.kitName);
    input.required = !!(show && required);
    var l = addressLabel(input);
    if (l) l.classList.toggle("kit-label--required", input.required);
  }
  function applyCountry(block) {
    var select = block.querySelector('[autocomplete~="country"]');
    if (!select) return null;
    var shape = addressFor(select.value), pc = block.querySelector('[autocomplete~="postal-code"]'), region = block.querySelector('[autocomplete~="address-level1"]');
    if (pc) {
      addressShow(pc, shape.postcode, pc.getAttribute("data-required") !== "false");
      if (addressLabel(pc)) addressLabel(pc).textContent = shape.postcodeLabel;
      pc.setAttribute("inputmode", shape.inputmode);
      if (shape.example) pc.setAttribute("placeholder", shape.example); else pc.removeAttribute("placeholder");
      if (shape.postcode && pc.value) fieldCommit(pc);
    }
    if (region) {
      var r = shape.region;
      addressShow(region, !!r, !!(r && r.required));
      if (r && addressLabel(region)) addressLabel(region).textContent = r.required ? r.label : r.label + " (optional)";
    }
    return shape;
  }
  function setupAddress(block) {
    if (block.kitAddress) return;
    block.kitAddress = true;
    applyCountry(block);
    block.addEventListener("change", function (e) {
      if (!e.target.matches || !e.target.matches('[autocomplete~="country"]')) return;
      applyCountry(block);
      emit(block, "address", { country: e.target.value });
    });
  }

  // Date range: <div class="kit-daterange" data-kit-daterange data-value="30d" aria-label="Period"></div> (data-presets
  // as for kit-range, without custom; data-min and data-max as yyyy-mm-dd; data-value="custom" with data-from and
  // data-to). A button shows the preset or the dates, named with the field ("Period, Last 30 days"), and opens a panel
  // with the presets and two native date fields with Apply: a preset applies when picked, the dates on Apply or Enter
  // (a reversed range is swapped; a date outside data-min and data-max shows an error under the fields). Escape or a
  // click beside it closes it back to the button. kit:range with detail.preset, from and to (yyyy-mm-dd, both
  // included; empty for all), as from kit-range.
  function setupDateRange(el) {
    if (el.kitDateRange) return;
    el.kitDateRange = true;
    var label = el.getAttribute("aria-label") || "Period", min = el.getAttribute("data-min") || "", max = el.getAttribute("data-max") || "";
    var presets = (el.getAttribute("data-presets") || "7d,30d,month,quarter,year,all").split(",").map(function (p) { return p.trim(); })
      .filter(function (p) { return p !== "custom" && (RANGE_NAMES[p] || /^\d+d$/.test(p)); });
    if (!el.getAttribute("role")) el.setAttribute("role", "group");
    var trigger = document.createElement("button"), panel = document.createElement("div");
    trigger.type = "button";
    trigger.className = "kit-select kit-daterange__trigger";
    panel.className = "kit-popover kit-daterange__panel";
    panel.hidden = true;
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-label", label);
    trigger.setAttribute("data-kit-popover", idOf(panel, "range"));
    trigger.setAttribute("aria-haspopup", "dialog");
    trigger.setAttribute("aria-expanded", "false");
    var list = document.createElement("div");
    list.className = "kit-daterange__presets";
    list.setAttribute("role", "group");
    list.setAttribute("aria-label", label + " presets");
    presets.forEach(function (p) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "kit-daterange__preset";
      b.setAttribute("data-preset", p);
      b.setAttribute("aria-pressed", "false");
      b.textContent = RANGE_NAMES[p] || ("Last " + parseInt(p, 10) + " days");
      list.appendChild(b);
    });
    var custom = document.createElement("div");
    custom.className = "kit-daterange__custom";
    custom.innerHTML = /* injection: fixed markup, no outside text */ '<div class="kit-field"><label class="kit-label">From</label><input class="kit-input" type="date"></div>' +
      '<div class="kit-field"><label class="kit-label">To</label><input class="kit-input" type="date"></div>' +
      '<p class="kit-error-text" hidden></p><button class="kit-btn kit-btn--primary kit-btn--sm" type="button">Apply</button>';
    var dates = custom.querySelectorAll("input"), fromIn = dates[0], toIn = dates[1], err = custom.querySelector("p"), apply = custom.querySelector("button");
    Array.prototype.forEach.call(custom.querySelectorAll("label"), function (l, i) { l.htmlFor = idOf(dates[i], "date"); if (min) dates[i].min = min; if (max) dates[i].max = max; });
    idOf(err, "range-error");
    panel.appendChild(list);
    panel.appendChild(custom);
    el.appendChild(trigger);
    el.appendChild(panel);
    function rangeShow(preset, from, to) {
      var text = preset === "custom" ? format.date(from) + " \u2013 " + format.date(to) : (RANGE_NAMES[preset] || ("Last " + parseInt(preset, 10) + " days"));
      trigger.textContent = text;
      trigger.setAttribute("aria-label", label + ", " + text);
      el.setAttribute("data-value", preset);
      el.setAttribute("data-from", from);
      el.setAttribute("data-to", to);
      el.classList.toggle("is-active", preset !== "all");
      Array.prototype.forEach.call(list.children, function (b) { b.setAttribute("aria-pressed", String(b.getAttribute("data-preset") === preset)); });
    }
    function done(preset, r) {
      rangeShow(preset, r.from, r.to);
      closePopovers();
      trigger.focus();
      emit(el, "range", { preset: preset, from: r.from, to: r.to });
    }
    function problem(text) {
      err.textContent = text;
      err.hidden = !text;
      [fromIn, toIn].forEach(function (i) { if (text) i.setAttribute("aria-invalid", "true"); else i.removeAttribute("aria-invalid"); describedBy(i, err.id, !!text); });
    }
    function applyDates() {
      var f = fromIn.value, t = toIn.value;
      if (!f || !t) { problem("Choose a start and an end date."); return; }
      if (f > t) { var x = f; f = t; t = x; fromIn.value = f; toIn.value = t; }   // reversed: swapped, not refused
      if ((min && f < min) || (max && t > max)) { problem("Choose dates from " + format.date(min || f) + " to " + format.date(max || t) + "."); return; }
      problem("");
      done("custom", { from: f, to: t });
    }
    list.addEventListener("click", function (e) { var b = closestOf(e.target, "[data-preset]"); if (b) done(b.getAttribute("data-preset"), rangeOf(b.getAttribute("data-preset"))); });
    apply.addEventListener("click", applyDates);
    custom.addEventListener("keydown", function (e) { if (e.key === "Enter" && !e.isComposing && e.target.localName === "input") { e.preventDefault(); applyDates(); } });
    var start = el.getAttribute("data-value");
    if (start === "custom" && el.getAttribute("data-from") && el.getAttribute("data-to")) { fromIn.value = el.getAttribute("data-from"); toIn.value = el.getAttribute("data-to"); rangeShow("custom", fromIn.value, toIn.value); }
    else { var p0 = presets.indexOf(start) >= 0 ? start : (presets.indexOf("all") >= 0 ? "all" : presets[0]), r0 = rangeOf(p0); rangeShow(p0, r0.from, r0.to); }
  }

  // Sheet with stops, for a phone or beside a map: <dialog class="kit-sheet" id="ID" data-kit-sheet data-detents="0.3 0.6 0.92"
  // data-detent="0" aria-labelledby="TITLE-ID"><div class="kit-sheet__grab"><span class="kit-sheet__handle" aria-hidden="true">
  // </span><div class="kit-sheet__head"><h2 class="kit-sheet__title" id="TITLE-ID">Stops</h2><button class="kit-btn kit-btn--sm"
  // type="button" data-kit-detent aria-expanded="false">Expand</button><button class="kit-btn kit-btn--ghost kit-btn--icon
  // kit-btn--sm" type="button" data-kit-close aria-label="Close">x</button></div></div><div class="kit-sheet__body">..</div>
  // </dialog>, opened by a button with data-kit-open="ID". The stops are shares of the window height (peek, medium and full
  // work too); the sheet is as tall as its highest stop and the lower stops are positions of it, so its content never
  // reflows. Drag the grab strip (any pointer), or the body by touch from the top of its scroll: on release it settles
  // on the stop nearest where it was heading, a flick down from the lowest stop or a pull past half below it closes it,
  // and a release that turns back returns it to where it started; past the highest stop it resists. data-kit-detent
  // steps through the stops (aria-expanded at the highest). Escape, the close button and a click beside it close it.
  // kit:detent with detail.index and detail.detent.
  var DETENT_NAMES = { peek: 0.25, medium: 0.5, full: 0.92 };
  function setupSheet(d) {
    if (d.kitSheet) return;
    d.kitSheet = true;
    var stops = (d.getAttribute("data-detents") || "0.5 0.92").split(/[\s,]+/).map(function (s) { return DETENT_NAMES[s] || parseFloat(s); })
      .filter(function (v) { return v > 0 && v <= 1; }).sort(function (a, b) { return a - b; });
    if (!stops.length) stops = [0.5];
    var first = clampNum(parseInt(d.getAttribute("data-detent"), 10) || 0, 0, stops.length - 1), index = first, y = 0, drag = null;
    var body = d.querySelector(".kit-sheet__body"), grab = d.querySelector(".kit-sheet__grab"), stepper = d.querySelector("[data-kit-detent]");
    function winH() { return window.innerHeight || document.documentElement.clientHeight || 800; }
    function offsetOf(i) { return (stops[stops.length - 1] - stops[i]) * winH(); }
    function place(px, animate) {
      y = px;
      d.style.transition = animate && !reducedMotion() ? "transform var(--kit-speed-slow) ease-out" : "none";
      d.style.transform = "translateY(" + Math.round(px) + "px)";
    }
    function sheetGo(i, animate) {
      index = clampNum(i, 0, stops.length - 1);
      d.style.height = Math.round(stops[stops.length - 1] * winH()) + "px";
      place(offsetOf(index), animate);
      if (stepper) stepper.setAttribute("aria-expanded", String(index === stops.length - 1));
      emit(d, "detent", { index: index, detent: stops[index] });
    }
    d.kitDetent = function (i) { sheetGo(i, true); };
    d.addEventListener("kit:open", function (e) { if (e.target === d) sheetGo(first, false); });
    if (d.open) sheetGo(first, false);
    d.addEventListener("click", function (e) { if (e.target === d) closePanel(d); });   // the backdrop
    if (stepper) stepper.addEventListener("click", function () { sheetGo(index === stops.length - 1 ? 0 : index + 1, true); });
    function sheetBegin(e, fromBody) {
      if (e.pointerType === "mouse" && e.button !== 0) return;
      drag = { id: e.pointerId, y0: e.clientY, start: y, from: index, decided: !fromBody, samples: [{ y: e.clientY, t: Date.now() }] };
      if (!fromBody) hold(e);
    }
    function hold(e) { try { d.setPointerCapture(e.pointerId); } catch (x) { /* not supported */ } d.style.transition = "none"; }
    if (grab) grab.addEventListener("pointerdown", function (e) { if (!closestOf(e.target, "button, a, input, select, textarea")) sheetBegin(e, false); });
    if (body) body.addEventListener("pointerdown", function (e) { if (e.pointerType === "touch" || e.pointerType === "pen") sheetBegin(e, true); });
    d.addEventListener("pointermove", function (e) {
      if (!drag || e.pointerId !== drag.id) return;
      var dy = e.clientY - drag.y0;
      if (!drag.decided) {
        if (Math.abs(dy) < 10) return;
        // From the body: down only from the top of its scroll, up only while the sheet is below its highest stop.
        if ((dy > 0 && (!body || body.scrollTop <= 0)) || (dy < 0 && index < stops.length - 1)) { drag.decided = true; drag.y0 = e.clientY; dy = 0; hold(e); }
        else { drag = null; return; }
      }
      e.preventDefault();
      drag.samples.push({ y: e.clientY, t: Date.now() });
      if (drag.samples.length > 5) drag.samples.shift();
      var to = drag.start + dy;
      place(to < 0 ? to * 0.3 : to, false);   // past the highest stop it resists
    });
    function release(e) {
      if (!drag || e.pointerId !== drag.id) return;
      var m = drag, s = m.samples, dt = s[s.length - 1].t - s[0].t, v = dt > 0 ? (s[s.length - 1].y - s[0].y) / dt : 0;
      drag = null;
      if (!m.decided) return;
      if (e.type === "pointercancel") { sheetGo(m.from, true); return; }
      var low = offsetOf(0), projected = y + v * 100, moved = y - m.start;
      if ((v > 0.11 && y >= low - 1) || projected > low + stops[0] * winH() / 2) { closePanel(d); return; }
      if (moved * v < 0 && Math.abs(v) > 0.05) { sheetGo(m.from, true); return; }   // the release turned back
      var best = 0;
      stops.forEach(function (st, i) { if (Math.abs(offsetOf(i) - projected) < Math.abs(offsetOf(best) - projected)) best = i; });
      sheetGo(best, true);
    }
    d.addEventListener("pointerup", release);
    d.addEventListener("pointercancel", release);
    // A capture taken away (the sheet closed, another element took it) ends the drag like a cancel.
    d.addEventListener("lostpointercapture", function (e) { if (drag && e.pointerId === drag.id) release({ type: "pointercancel", pointerId: e.pointerId }); });
  }

  // Carousel (like items where seeing a few is enough; what everyone must see goes in a grid or list; inside another
  // section a div with role="region"): <section class="kit-carousel" data-kit-carousel aria-label="Recent reports"><div class="kit-carousel__head"><h2 class="kit-h3">
  // Recent reports</h2><span class="kit-carousel__pos"></span><button class="kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm"
  // type="button" data-kit-prev aria-label="Previous reports">..</button><button ... data-kit-next aria-label="Next reports">
  // ..</button></div><ul class="kit-carousel__track" tabindex="0" aria-label="Reports"><li class="kit-carousel__item">..</li>
  // </ul></section>. The browser scrolls (snap, momentum); kit.js keeps the buttons (aria-disabled at their end), the
  // position ("4-6 of 12") and the edge fade (data-more on the track) in step, after a swipe too. The buttons scroll a
  // page, Left and Right on the track one item, Home and End to the ends; smooth only without reduced motion. No
  // autoplay. kit:carousel with detail.atStart and detail.atEnd when an end changes.
  function setupCarousel(root) {
    var track = root.querySelector(".kit-carousel__track");
    if (root.kitCarousel || !track) return;
    root.kitCarousel = true;
    var prev = root.querySelector("[data-kit-prev]"), next = root.querySelector("[data-kit-next]"), pos = root.querySelector(".kit-carousel__pos"), ends = "", frame = 0;
    var items = function () { return Array.prototype.slice.call(track.children); };
    if (!track.hasAttribute("tabindex")) track.tabIndex = 0;
    function scrollToX(x) {
      x = clampNum(x, 0, Math.max(0, track.scrollWidth - track.clientWidth));
      if (typeof track.scrollTo === "function") { try { track.scrollTo({ left: x, behavior: reducedMotion() ? "auto" : "smooth" }); } catch (e) { track.scrollLeft = x; } }
      else track.scrollLeft = x;
      update();
    }
    function update() {
      var left = track.scrollLeft, w = track.clientWidth, atStart = left <= 1, atEnd = left + w >= track.scrollWidth - 1;
      [[prev, atStart], [next, atEnd]].forEach(function (p) { if (p[0]) { if (p[1]) p[0].setAttribute("aria-disabled", "true"); else p[0].removeAttribute("aria-disabled"); } });
      track.setAttribute("data-more", atStart && atEnd ? "none" : atStart ? "end" : atEnd ? "start" : "both");
      var list = items(), seen = [];
      list.forEach(function (it, i) { if (it.offsetWidth && it.offsetLeft + it.offsetWidth > left + 1 && it.offsetLeft < left + w - 1) seen.push(i + 1); });
      if (pos) pos.textContent = seen.length ? (seen.length > 1 ? seen[0] + "\u2013" + seen[seen.length - 1] : seen[0]) + " of " + list.length : list.length + " items";
      var now = atStart + "," + atEnd;
      if (now !== ends) { var was = ends; ends = now; if (was) emit(root, "carousel", { atStart: atStart, atEnd: atEnd }); }
    }
    if (prev) prev.addEventListener("click", function () { scrollToX(track.scrollLeft - track.clientWidth); });
    if (next) next.addEventListener("click", function () { scrollToX(track.scrollLeft + track.clientWidth); });
    track.addEventListener("keydown", function (e) {
      if (e.target !== track) return;
      var left = track.scrollLeft, list = items(), to = null;
      if (e.key === "ArrowRight") { var n = list.filter(function (it) { return it.offsetLeft > left + 1; })[0]; to = n ? n.offsetLeft : track.scrollWidth; }
      else if (e.key === "ArrowLeft") { var p = list.filter(function (it) { return it.offsetLeft < left - 1; }).pop(); to = p ? p.offsetLeft : 0; }
      else if (e.key === "Home") to = 0;
      else if (e.key === "End") to = track.scrollWidth;
      if (to === null) return;
      e.preventDefault();
      scrollToX(to);
    });
    var later = function () { if (frame) return; frame = (window.requestAnimationFrame || setTimeout)(function () { frame = 0; update(); }); };
    track.addEventListener("scroll", later, { passive: true });
    window.addEventListener("resize", later);
    update();
  }

  // Reorder by a handle: <ul class="kit-list kit-reorder" data-kit-reorder aria-label="Agenda"> of rows that each hold
  // <button class="kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm kit-reorder__handle" type="button" data-kit-handle
  // aria-label="Move Budget review">(grip-vertical icon)</button>. Drag the handle (after 4 px): the row stays in place,
  // dimmed, and a line shows where it lands; the order changes once, on the drop; Escape restores. On the handle: Space
  // or Enter picks the row up, Up and Down move the line, Home and End to the ends, Space or Enter drops, Escape or
  // leaving the handle cancels; Alt+Up/Down moves one place at once. The focus stays on the handle and every step is read
  // out. kit:reorder with detail.item, id (data-id), from and to (0-based).
  function setupReorder(list) {
    if (list.kitReorder) return;
    list.kitReorder = true;
    var line = document.createElement("li"), moving = null;
    line.className = "kit-reorder__line";
    line.hidden = true;
    line.setAttribute("aria-hidden", "true");
    list.appendChild(line);
    function reorderRows() { return Array.prototype.filter.call(list.children, function (c) { return c !== line; }); }
    function rowOf(el) { while (el && el.parentNode !== list) el = el.parentNode; return el; }
    function nameOf(r) { var t = r.querySelector(".kit-list__title"); return r.getAttribute("data-name") || (t || r).textContent.trim(); }
    function where(i) { return "position " + (i + 1) + " of " + reorderRows().length; }
    function showLine(to) {
      if (to === moving.from) { line.hidden = true; return; }
      var ref = reorderRows()[to].getBoundingClientRect(), box = list.getBoundingClientRect();
      line.hidden = false;
      line.style.top = Math.round((to > moving.from ? ref.bottom : ref.top) - box.top + list.scrollTop - 1) + "px";
    }
    function reorderPick(row, handle, pointer) {
      moving = { row: row, from: reorderRows().indexOf(row), handle: handle, pointer: pointer };
      moving.to = moving.from;
      row.classList.add("is-moving");
      if (!pointer) announce("Picked up " + nameOf(row) + ", " + where(moving.from) + ". Up and Down move it, Space drops it, Escape cancels.");
    }
    function moveTo(to) {
      moving.to = clampNum(to, 0, reorderRows().length - 1);
      showLine(moving.to);
      if (!moving.pointer) announce(where(moving.to));
    }
    function put(row, from, to, handle) {
      var all = reorderRows();
      list.insertBefore(row, to > from ? all[to].nextSibling : all[to]);
      if (handle) handle.focus();
      announce(nameOf(row) + " moved to " + where(to) + ".");
      emit(list, "reorder", { item: row, id: row.getAttribute("data-id") || "", from: from, to: to });
    }
    function finish(drop) {
      if (!moving) return;
      var m = moving;
      moving = null;
      m.row.classList.remove("is-moving");
      line.hidden = true;
      if (drop && m.to !== m.from) put(m.row, m.from, m.to, m.handle);
      else announce(drop ? nameOf(m.row) + " dropped at " + where(m.from) + "." : "Move cancelled. " + nameOf(m.row) + " is back at " + where(m.from) + ".");
    }
    list.addEventListener("keydown", function (e) {
      var h = closestOf(e.target, "[data-kit-handle]");
      if (!h || !list.contains(h) || isOff(h)) return;
      var row = rowOf(h), i = reorderRows().indexOf(row), n = reorderRows().length, k = e.key;
      if (e.altKey && (k === "ArrowUp" || k === "ArrowDown")) {
        e.preventDefault();
        finish(false);
        var to = clampNum(i + (k === "ArrowUp" ? -1 : 1), 0, n - 1);
        if (to !== i) put(row, i, to, h);
        return;
      }
      if (k === " " || k === "Enter") { e.preventDefault(); if (moving && moving.row === row) finish(true); else { finish(false); reorderPick(row, h, false); } return; }
      if (!moving || moving.row !== row) return;
      if (k === "ArrowUp" || k === "ArrowDown" || k === "Home" || k === "End") { e.preventDefault(); moveTo(k === "Home" ? 0 : k === "End" ? n - 1 : moving.to + (k === "ArrowUp" ? -1 : 1)); }
      else if (k === "Escape") { escapeHandled(e); finish(false); }
    });
    list.addEventListener("focusout", function (e) { if (moving && !moving.pointer && e.target === moving.handle) finish(false); });
    list.addEventListener("pointerdown", function (e) {
      var h = closestOf(e.target, "[data-kit-handle]");
      if (!h || !list.contains(h) || e.button !== 0 || isOff(h)) return;
      var row = rowOf(h), y0 = e.clientY, started = false, id = e.pointerId;
      function reorderMove(ev) {
        if (ev.pointerId !== id) return;
        if (!started) {
          if (Math.abs(ev.clientY - y0) < 4) return;
          started = true;
          try { h.setPointerCapture(id); } catch (x) { /* not supported */ }
          finish(false);
          reorderPick(row, h, true);
        }
        ev.preventDefault();
        var to = 0;
        reorderRows().forEach(function (r) { if (r === row) return; var b = r.getBoundingClientRect(); if (ev.clientY > b.top + b.height / 2) to++; });
        moveTo(to);
      }
      function reorderStop(ev) { if (ev.pointerId !== id) return; reorderOff(); if (started) finish(ev.type === "pointerup"); }
      function reorderKey(ev) { if (ev.key === "Escape" && started) { escapeHandled(ev); reorderOff(); finish(false); } }
      function reorderOff() { document.removeEventListener("pointermove", reorderMove); document.removeEventListener("pointerup", reorderStop); document.removeEventListener("pointercancel", reorderStop); document.removeEventListener("keydown", reorderKey, true); }
      document.addEventListener("pointermove", reorderMove);
      document.addEventListener("pointerup", reorderStop);
      document.addEventListener("pointercancel", reorderStop);
      document.addEventListener("keydown", reorderKey, true);
    });
  }

  // Swipe actions, a touch shortcut only (every action is also in the row's visible kit-menu): <ul class="kit-list"
  // data-kit-swipe> of <li class="kit-swipe" data-name="Budget review"><div class="kit-swipe__actions"><button class=
  // "kit-swipe__action" type="button" data-value="archive" data-full>Archive</button><button class="kit-swipe__action
  // kit-swipe__action--danger" type="button" data-value="delete" data-remove="Message deleted">Delete</button></div>
  // <div class="kit-swipe__row">(the row, with its kit-menu)</div></li>. Touch and pen swipe a row toward the start (a
  // mouse or the wheel never does); the direction is decided in the first 10 px and kept. A flick or a swipe past half
  // the actions opens them, else they close; past 60% of the row the data-full action runs when let go (a flick never
  // runs one). One row open at a time; a tap on the row, a press elsewhere, a scroll or Escape closes it. A closed
  // panel is out of the Tab order; its buttons are named with the row ("Archive Budget review"). data-remove hides
  // the row at once with a toast and Undo; it is final when the toast ends. kit:swipe with detail.item, value and
  // state (done, removed, restored, committed).
  var swipeOpen = null;
  function swipeParts(li) { return { actions: li.querySelector(".kit-swipe__actions"), row: li.querySelector(".kit-swipe__row") }; }
  function swipeShow(li, x, animate) {
    var p = swipeParts(li);
    if (!p.row || !p.actions) return;
    p.row.style.transition = animate && !reducedMotion() ? "transform var(--kit-speed) ease-out" : "none";
    p.row.style.transform = x ? "translateX(" + Math.round(x) + "px)" : "";
    li.classList.toggle("is-open", !!x);
    if (x) p.actions.removeAttribute("inert"); else p.actions.setAttribute("inert", "");
  }
  function swipeClose(li, animate) { if (!li) return; swipeShow(li, 0, animate); if (swipeOpen === li) swipeOpen = null; }
  function swipeName(li) { var t = li.querySelector(".kit-list__title"); return li.getAttribute("data-name") || (t ? t.textContent.trim() : ""); }
  function swipeAct(li, btn) {
    var value = btn.getAttribute("data-value") || btn.textContent.trim(), gone = btn.getAttribute("data-remove"), undone = false;
    swipeClose(li, false);
    if (!gone) { emit(li, "swipe", { item: li, value: value, state: "done" }); return; }
    li.hidden = true;
    emit(li, "swipe", { item: li, value: value, state: "removed" });
    toast(gone, {
      action: { label: "Undo", onClick: function () { undone = true; li.hidden = false; emit(li, "swipe", { item: li, value: value, state: "restored" }); } },
      onClose: function () { if (!undone) emit(li, "swipe", { item: li, value: value, state: "committed" }); }
    });
  }
  function setupSwipe(list) {
    if (list.kitSwipe) return;
    list.kitSwipe = true;
    Array.prototype.forEach.call(list.querySelectorAll(".kit-swipe"), function (li) {
      var p = swipeParts(li), name = swipeName(li);
      if (!p.actions) return;
      p.actions.setAttribute("inert", "");
      Array.prototype.forEach.call(p.actions.querySelectorAll("button"), function (b) { if (name && !b.getAttribute("aria-label")) b.setAttribute("aria-label", b.textContent.trim() + " " + name); });
    });
    list.addEventListener("pointerdown", function (e) {
      if (e.pointerType !== "touch" && e.pointerType !== "pen") return;
      var li = closestOf(e.target, ".kit-swipe"), p = li && swipeParts(li);
      if (!p || !p.row || !p.actions || !p.row.contains(e.target)) return;
      if (swipeOpen && swipeOpen !== li) swipeClose(swipeOpen, true);
      var sign = getComputedStyle(list).direction === "rtl" ? 1 : -1, w = p.actions.offsetWidth || 1, base = li.classList.contains("is-open") ? sign * w : 0;
      var s = { id: e.pointerId, x0: e.clientX, y0: e.clientY, axis: "", x: base, raw: base * sign, samples: [] };
      function swipeMove(ev) {
        if (ev.pointerId !== s.id) return;
        var dx = ev.clientX - s.x0, dy = ev.clientY - s.y0;
        if (!s.axis) {
          if (Math.abs(dx) < 10 && Math.abs(dy) < 10) return;
          s.axis = Math.abs(dx) > Math.abs(dy) ? "x" : "y";
          if (s.axis === "y") { swipeOff(); return; }   // the list scrolls
          try { p.row.setPointerCapture(s.id); } catch (x) { /* not supported */ }
          li.classList.add("is-swiping");
          p.actions.removeAttribute("inert");
        }
        ev.preventDefault();
        s.raw = (base + dx) * sign;
        s.samples.push({ x: ev.clientX, t: Date.now() });
        if (s.samples.length > 5) s.samples.shift();
        var along = s.raw < 0 ? 0 : s.raw > w ? w + (s.raw - w) * 0.35 : s.raw;   // past its actions the row resists
        s.x = sign * along;
        swipeShow(li, s.x, false);
      }
      function swipeUp(ev) {
        if (ev.pointerId !== s.id) return;
        swipeOff();
        if (s.axis !== "x") return;
        li.classList.remove("is-swiping");
        li.kitSwipedAt = Date.now();   // the click that follows the swipe does nothing
        var a = s.samples[0], b = s.samples[s.samples.length - 1], dt = a && b ? b.t - a.t : 0, v = dt > 0 ? (b.x - a.x) / dt * sign : 0;
        var full = p.actions.querySelector("[data-full]"), flick = Math.abs(v) > 0.11;
        if (ev.type === "pointerup" && full && !flick && s.raw > 0.6 * (li.offsetWidth || Infinity)) { swipeAct(li, full); return; }
        var open = ev.type === "pointerup" && (flick ? v > 0 : s.x * sign > w / 2);
        if (open) { swipeShow(li, sign * w, true); swipeOpen = li; } else swipeClose(li, true);
      }
      function swipeOff() { document.removeEventListener("pointermove", swipeMove); document.removeEventListener("pointerup", swipeUp); document.removeEventListener("pointercancel", swipeUp); }
      document.addEventListener("pointermove", swipeMove, { passive: false });
      document.addEventListener("pointerup", swipeUp);
      document.addEventListener("pointercancel", swipeUp);
    });
    list.addEventListener("click", function (e) {
      var li = closestOf(e.target, ".kit-swipe");
      if (!li) return;
      var act = closestOf(e.target, ".kit-swipe__action");
      if (act && li.contains(act)) { swipeAct(li, act); return; }
      if ((li.classList.contains("is-open") || Date.now() - (li.kitSwipedAt || 0) < 400) && swipeParts(li).row.contains(e.target)) {
        e.preventDefault();
        e.stopPropagation();   // a tap on an open row closes it and activates nothing
        swipeClose(li, true);
      }
    }, true);
    list.addEventListener("scroll", function () { swipeClose(swipeOpen, true); }, { passive: true });
  }
  document.addEventListener("pointerdown", function (e) { if (swipeOpen && !swipeOpen.contains(e.target)) swipeClose(swipeOpen, true); });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape" && swipeOpen) { escapeHandled(e); swipeClose(swipeOpen, true); } });
  window.addEventListener("scroll", function () { if (swipeOpen) swipeClose(swipeOpen, true); }, { passive: true });

  // Splitter: <div class="kit-splitpane"><div class="kit-splitpane__pane" id="list-pane">..</div><div class="kit-splitter"
  // role="separator" tabindex="0" aria-controls="list-pane" aria-label="Resize the list" data-kit-splitter data-min="200"
  // data-default="320" data-persist="mail-list"></div><div class="kit-splitpane__pane">..</div></div> (kit-splitpane--stacked
  // with aria-orientation="horizontal" for panes above each other). Drag the bar (it follows the pointer, Escape puts it
  // back), arrows step 16 px (Shift: 64; data-step), Home and End go to the limits, Enter folds the pane to its minimum
  // and back, a double click restores data-default. The other pane keeps data-rest (160 px). data-persist keeps the size
  // per key; a smaller window narrows the pane but keeps the chosen size for when room returns. aria-disabled keeps the
  // size. kit:resize with detail.size once per finished change.
  function setupSplitter(bar) {
    var pane = document.getElementById(bar.getAttribute("aria-controls") || "") || bar.previousElementSibling;
    if (bar.kitSplitter || !pane) return;
    bar.kitSplitter = true;
    var wrap = bar.parentNode, vertical = bar.getAttribute("aria-orientation") !== "horizontal", key = bar.getAttribute("data-persist"), folded = null;
    if (!bar.getAttribute("role")) bar.setAttribute("role", "separator");
    if (!bar.hasAttribute("tabindex")) bar.tabIndex = 0;
    bar.setAttribute("aria-orientation", vertical ? "vertical" : "horizontal");
    bar.setAttribute("aria-controls", idOf(pane, "pane"));
    var attr = function (a, f) { var v = parseFloat(bar.getAttribute(a)); return isNaN(v) ? f : v; };
    var size = function (el) { var r = el.getBoundingClientRect(); return vertical ? r.width : r.height; };
    function limits() {
      var lo = attr("data-min", 120), hi = attr("data-max", Infinity), whole = size(wrap);
      if (whole > 0) hi = Math.min(hi, whole - size(bar) - attr("data-rest", 160));   // not laid out (hidden): no room limit
      return { lo: lo, hi: Math.max(lo, hi) };
    }
    function splitApply(px, send) {
      var l = limits(), s = Math.round(clampNum(px, l.lo, l.hi));
      pane.style.flexBasis = s + "px";
      bar.setAttribute("aria-valuemin", String(Math.round(l.lo)));
      if (isFinite(l.hi)) bar.setAttribute("aria-valuemax", String(Math.round(l.hi))); else bar.removeAttribute("aria-valuemax");
      bar.setAttribute("aria-valuenow", String(s));
      if (send) { chosen = s; if (key) writeStore("kit-split:" + key, String(s)); emit(bar, "resize", { size: s }); }
      return s;
    }
    function now() { return parseFloat(bar.getAttribute("aria-valuenow")) || size(pane) || attr("data-default", 280); }
    var stored = key ? parseFloat(readStore("kit-split:" + key)) : NaN, chosen = isNaN(stored) ? attr("data-default", size(pane) || 280) : stored;
    splitApply(chosen, false);
    bar.addEventListener("keydown", function (e) {
      if (isOff(bar)) return;
      var k = e.key, rtl = vertical && getComputedStyle(bar).direction === "rtl", step = attr("data-step", 16) * (e.shiftKey ? 4 : 1), l = limits(), at = now(), to = null;
      var less = vertical ? (rtl ? "ArrowRight" : "ArrowLeft") : "ArrowUp", more = vertical ? (rtl ? "ArrowLeft" : "ArrowRight") : "ArrowDown";
      if (k === less) to = at - step;
      else if (k === more) to = at + step;
      else if (k === "Home") to = l.lo;
      else if (k === "End") to = l.hi;
      else if (k === "Enter") { if (at > l.lo) { folded = at; to = l.lo; } else to = folded || attr("data-default", 280); }
      if (to === null || !isFinite(to)) return;
      e.preventDefault();
      splitApply(to, true);
    });
    bar.addEventListener("dblclick", function () { if (!isOff(bar)) splitApply(attr("data-default", 280), true); });
    bar.addEventListener("pointerdown", function (e) {
      if (e.button !== 0 || isOff(bar)) return;
      e.preventDefault();
      var from = now(), p0 = vertical ? e.clientX : e.clientY, flip = vertical && getComputedStyle(bar).direction === "rtl", id = e.pointerId, last = from;
      try { bar.setPointerCapture(id); } catch (x) { /* not supported */ }
      bar.focus();
      wrap.classList.add("is-resizing");
      function splitMove(ev) { if (ev.pointerId === id) { var d = (vertical ? ev.clientX : ev.clientY) - p0; last = splitApply(from + (flip ? -d : d), false); } }
      function end(cancel) {
        document.removeEventListener("pointermove", splitMove); document.removeEventListener("pointerup", splitUp); document.removeEventListener("pointercancel", splitUp); document.removeEventListener("keydown", splitKey, true);
        wrap.classList.remove("is-resizing");
        if (cancel) splitApply(from, false); else if (last !== from) splitApply(last, true);
      }
      function splitUp(ev) { if (ev.pointerId === id) end(ev.type === "pointercancel"); }
      function splitKey(ev) { if (ev.key === "Escape") { escapeHandled(ev); end(true); } }
      document.addEventListener("pointermove", splitMove);
      document.addEventListener("pointerup", splitUp);
      document.addEventListener("pointercancel", splitUp);
      document.addEventListener("keydown", splitKey, true);
    });
    window.addEventListener("resize", function () { splitApply(chosen, false); });
  }

  // Disclosure, for the rare part of a page (a plain section may stay a details kit-accordion): <div class="kit-disclosure"
  // data-kit-disclosure> with per section <h3 class="kit-disclosure__heading"><button class="kit-disclosure__head"
  // type="button" aria-expanded="false" aria-controls="P1">Delivery</button></h3><div class="kit-disclosure__panel" id="P1">
  // <div class="kit-disclosure__body">..</div></div>. A click, Enter or Space toggles and the focus stays on the button.
  // The panel slides open (at once under reduced motion and at the first placement); a closed one is out of the Tab and
  // reading order (inert). data-single keeps one open; data-persist="KEY" keeps the open sections across visits. A
  // section with an invalid field opens by itself. kit:toggle with detail.open, detail.trigger and detail.panel.
  function disclosureHeads(root) { return Array.prototype.filter.call(root.querySelectorAll(".kit-disclosure__head[aria-controls]"), function (b) { return b.closest("[data-kit-disclosure]") === root; }); }
  function disclosureSet(root, btn, open, send) {
    var p = document.getElementById(btn.getAttribute("aria-controls"));
    if (!p) return;
    btn.setAttribute("aria-expanded", String(open));
    var body = p.querySelector(".kit-disclosure__body");
    p.setAttribute("data-state", open ? "open" : "closed");
    if (FIND_OPENS && body) findable(root, p, body, open);
    else if (open) p.removeAttribute("inert"); else p.setAttribute("inert", "");
    if (send) emit(root, "toggle", { open: open, trigger: btn, panel: p });
  }
  // Find in page: where the browser supports hidden="until-found", a closed section's body gets it (after the
  // slide) instead of inert, so the browser's find still reaches its text and opens the section (beforematch).
  var FIND_OPENS = !!document.documentElement && "onbeforematch" in document.documentElement;
  function findable(root, p, body, open) {
    p.classList.add("is-findable");
    p.removeAttribute("inert");
    clearTimeout(p.kitFindTimer);
    if (open) { body.removeAttribute("hidden"); return; }
    var hide = function () { if (p.getAttribute("data-state") === "closed") body.setAttribute("hidden", "until-found"); };
    if (root.hasAttribute("data-ready") && !reducedMotion()) p.kitFindTimer = setTimeout(hide, 400); else hide();
  }
  function setupDisclosure(root) {
    if (root.kitDisclosure) return;
    root.kitDisclosure = true;
    var key = root.getAttribute("data-persist"), saved = null;
    try { saved = key ? JSON.parse(readStore("kit-open:" + key) || "null") : null; } catch (e) { saved = null; }
    disclosureHeads(root).forEach(function (b) {
      var id = b.getAttribute("aria-controls"), p = document.getElementById(id);
      var open = saved ? saved.indexOf(id) >= 0 : b.getAttribute("aria-expanded") === "true";
      disclosureSet(root, b, open || !!(p && p.querySelector('[aria-invalid="true"]')), false);
    });
    // The browser found text in a closed section: it opens, as if its button was pressed.
    root.addEventListener("beforematch", function (e) {
      var b = disclosureHeads(root).filter(function (h) { var p = document.getElementById(h.getAttribute("aria-controls")); return p && p.contains(e.target); })[0];
      if (b) disclosureSet(root, b, true, true);
    });
    var ready = function () { root.setAttribute("data-ready", ""); };   // from now on the panels slide
    if (window.requestAnimationFrame) requestAnimationFrame(function () { requestAnimationFrame(ready); }); else ready();
    root.addEventListener("click", function (e) {
      var b = closestOf(e.target, ".kit-disclosure__head[aria-controls]");
      if (!b || b.closest("[data-kit-disclosure]") !== root) return;
      var open = b.getAttribute("aria-expanded") !== "true";
      if (open && root.hasAttribute("data-single")) disclosureHeads(root).forEach(function (o) { if (o !== b && o.getAttribute("aria-expanded") === "true") disclosureSet(root, o, false, true); });
      disclosureSet(root, b, open, true);
      if (key) writeStore("kit-open:" + key, JSON.stringify(disclosureHeads(root).filter(function (o) { return o.getAttribute("aria-expanded") === "true"; }).map(function (o) { return o.getAttribute("aria-controls"); })));
    });
  }
  // A field that fails its check is never hidden in a closed section: the sections around it open.
  function openAround(field) {
    var p = field && field.closest ? field.closest('.kit-disclosure__panel[data-state="closed"]') : null;
    while (p) {
      var b = document.querySelector('[aria-controls="' + p.id + '"]'), root = b && b.closest("[data-kit-disclosure]");
      if (!root) break;
      disclosureSet(root, b, true, true);
      p = p.parentNode && p.parentNode.closest ? p.parentNode.closest('.kit-disclosure__panel[data-state="closed"]') : null;
    }
    var d = field && field.closest ? field.closest("details:not([open])") : null;
    if (d) d.open = true;
  }
  document.addEventListener("invalid", function (e) { openAround(e.target); }, true);

  // Toolbar overflow: data-kit-overflow on a kit-toolbar (role="toolbar" with a name) that stays on one line. Buttons
  // that do not fit move, from the end (data-priority="low" first), into a More menu at its end, in the same order with
  // the same names and states (a pressed toggle is a ticked item, an unavailable one aria-disabled); choosing one presses
  // the button. data-kit-keep, a primary button, the current item and fields never fold. The row is measured before it
  // is painted and again only when its width changes; a folded button comes back with 6 px to spare. A focused button
  // that folds hands the focus to More. data-more-label names the More button ("More actions"). row.kitRefit() measures
  // again after the buttons changed. kit:overflow with detail.folded (the folded buttons).
  function setupOverflow(row) {
    if (row.kitOverflow) return;
    row.kitOverflow = true;
    var more = document.createElement("div");
    more.className = "kit-menu kit-overflow__more";
    more.innerHTML = /* injection: fixed markup and the kit's icon */ '<button class="kit-btn kit-btn--ghost kit-btn--icon" type="button" data-kit-menu aria-haspopup="menu" aria-expanded="false">' + lineIcon("more") + '</button><div class="kit-menu__list" role="menu" hidden></div>';
    var moreBtn = more.firstChild, menu = more.lastChild, lastW = -1, folded = [];
    moreBtn.setAttribute("aria-label", row.getAttribute("data-more-label") || "More");
    more.hidden = true;
    row.appendChild(more);
    function items() { return Array.prototype.filter.call(row.children, function (c) { return c !== more; }); }
    function foldable(c) {
      return c.matches("button, a[href], [role=button]") && !c.hasAttribute("data-kit-keep") && !c.classList.contains("kit-btn--primary") &&
        !(c.getAttribute("aria-current") && c.getAttribute("aria-current") !== "false");
    }
    function itemFor(c, i) {
      var b = document.createElement("button"), pressed = c.getAttribute("aria-pressed");
      b.type = "button";
      b.className = "kit-menu__item";
      b.setAttribute("data-value", "fold-" + i);
      b.setAttribute("role", pressed ? "menuitemcheckbox" : "menuitem");
      if (pressed) b.setAttribute("aria-checked", String(pressed === "true"));
      if (isOff(c) || c.disabled) b.setAttribute("aria-disabled", "true");
      b.textContent = c.getAttribute("aria-label") || c.textContent.trim();
      b.kitFor = c;
      return b;
    }
    function fit(force) {
      var w = row.clientWidth;
      if (!force && Math.abs(w - lastW) <= 0.5) return;
      lastW = w;
      var list = items(), had = folded.length, gap = parseFloat(getComputedStyle(row).columnGap) || 0;
      list.forEach(function (c) { if (c.kitFolded) { c.hidden = false; c.kitFolded = false; } });
      more.hidden = false;
      var sizes = list.map(function (c) { return c.classList.contains("kit-toolbar__spacer") ? 0 : rowWidth(c) + gap; });
      var total = sizes.reduce(function (a, b) { return a + b; }, 0), room = w - (had ? 6 : 0), out = [];
      if (w > 0 && total > room) {
        var order = list.map(function (c, i) { return i; }).filter(function (i) { return foldable(list[i]); }).sort(function (a, b) {
          var la = list[a].getAttribute("data-priority") === "low", lb = list[b].getAttribute("data-priority") === "low";
          return la !== lb ? (la ? -1 : 1) : b - a;
        });
        var withMore = total + rowWidth(more) + gap;
        for (var j = 0; j < order.length && withMore > room; j++) { withMore -= sizes[order[j]]; out.push(list[order[j]]); }
      }
      out.sort(function (a, b) { return list.indexOf(a) - list.indexOf(b); });
      var focused = document.activeElement;
      out.forEach(function (c) { c.hidden = true; c.kitFolded = true; });
      more.hidden = !out.length;
      menu.innerHTML = "";
      out.forEach(function (c, i) { menu.appendChild(itemFor(c, i)); });
      if (focused && out.some(function (c) { return c === focused || c.contains(focused); })) moreBtn.focus();
      var changed = out.length !== folded.length || out.some(function (c, i) { return c !== folded[i]; });
      folded = out;
      if (changed) emit(row, "overflow", { folded: out.slice() });
    }
    // The states shown when the menu opens, as the buttons have them now.
    moreBtn.addEventListener("click", function () { menu.innerHTML = ""; folded.forEach(function (c, i) { menu.appendChild(itemFor(c, i)); }); });
    more.addEventListener("kit:menu", function (e) {
      e.stopPropagation();
      var b = menu.querySelector('[data-value="' + e.detail.value + '"]');
      if (b && b.kitFor && !isOff(b.kitFor)) b.kitFor.click();
    });
    row.kitRefit = function () { fit(true); };
    if (window.ResizeObserver) new ResizeObserver(function () { fit(false); }).observe(row); else window.addEventListener("resize", function () { fit(false); });
    fit(true);
  }

  // Breadcrumbs on one line: data-kit-breadcrumbs on <nav class="kit-breadcrumbs" aria-label="Breadcrumb"><ol>...</ol></nav>.
  // When the trail is wider than its box, the middle levels fold, from the start of the middle, into a "..." menu after
  // the first level; the first level and the current page always stay, and room unfolds them again. A long level name
  // is cut at about 24 letters with the whole name as its title. The last level gets aria-current="page" when none has it.
  function setupCrumbs(nav) {
    var ol = nav.querySelector("ol");
    if (nav.kitCrumbs || !ol) return;
    nav.kitCrumbs = true;
    var levels = Array.prototype.slice.call(ol.children), lastW = -1;
    if (levels.length && !ol.querySelector("[aria-current]")) levels[levels.length - 1].setAttribute("aria-current", "page");
    levels.forEach(function (l) { var a = l.querySelector("a"); if (a && !a.title) a.title = a.textContent.trim(); });
    var li = document.createElement("li");
    li.className = "kit-breadcrumbs__more";
    li.hidden = true;
    li.innerHTML = '<div class="kit-menu kit-menu--left"><button class="kit-btn kit-btn--ghost kit-btn--sm" type="button" data-kit-menu aria-haspopup="menu" aria-expanded="false">\u2026</button><div class="kit-menu__list" role="menu" hidden></div></div>';
    var btn = li.querySelector("button"), menu = li.querySelector('[role="menu"]');
    if (levels.length > 2) ol.insertBefore(li, levels[1]);
    function crumbsFit(force) {
      var w = ol.clientWidth;
      if (!force && Math.abs(w - lastW) <= 0.5) return;
      lastW = w;
      levels.forEach(function (l) { l.hidden = false; });
      li.hidden = true;
      var middle = levels.slice(1, -1), n = 0;
      while (w > 0 && n < middle.length && ol.scrollWidth > ol.clientWidth + 0.5) { li.hidden = false; middle[n].hidden = true; n++; }
      menu.innerHTML = "";
      middle.slice(0, n).forEach(function (l) {
        var a = l.querySelector("a"), item = document.createElement(a ? "a" : "button");
        item.className = "kit-menu__item";
        item.setAttribute("role", "menuitem");
        if (a) item.href = a.getAttribute("href"); else { item.type = "button"; item.setAttribute("aria-disabled", "true"); }
        item.textContent = (a || l).textContent.trim();
        menu.appendChild(item);
      });
      btn.setAttribute("aria-label", n === 1 ? "Show 1 more level" : "Show " + n + " more levels");
    }
    nav.kitRefit = function () { crumbsFit(true); };
    if (window.ResizeObserver) new ResizeObserver(function () { crumbsFit(false); }).observe(nav); else window.addEventListener("resize", function () { crumbsFit(false); });
    crumbsFit(true);
  }

  // ---------- Parts added from a comparison with an open-source headless component library (MIT), 28 Nov 2026 ----------

  // Menubar: <div class="kit-menubar" role="menubar" aria-label="..."> of kit-menu blocks whose buttons
  // (data-kit-menu) become role="menuitem" and one tab stop. ArrowLeft and ArrowRight move between them
  // (round), Home and End go to the ends, ArrowDown opens. While a menu is open, ArrowLeft and ArrowRight in
  // it, or a pointer on another button, open the neighbour instead.
  function menubarButtons(bar) { return Array.prototype.filter.call(bar.querySelectorAll("[data-kit-menu]"), function (b) { return b.closest('[role="menubar"]') === bar; }); }
  function menubarRove(bar, cur) { menubarButtons(bar).forEach(function (b) { b.setAttribute("tabindex", b === cur ? "0" : "-1"); }); cur.focus(); }
  function menubarMove(list, step) {
    var btn = menuButtonOf(list), bar = btn && btn.closest('[role="menubar"]');
    if (!bar) return false;
    var all = menubarButtons(bar), to = all[(all.indexOf(btn) + step + all.length) % all.length];
    if (!to || to === btn) return false;
    closeMenus();
    menubarRove(bar, to);
    toggleMenu(to);
    return true;
  }
  function setupMenubar(bar) {
    if (bar.kitMenubar) return;
    bar.kitMenubar = true;
    menubarButtons(bar).forEach(function (b, i) { b.setAttribute("role", "menuitem"); b.setAttribute("tabindex", i ? "-1" : "0"); });
    bar.addEventListener("keydown", function (e) {
      var b = closestOf(e.target, "[data-kit-menu]"), list = menubarButtons(bar), i = list.indexOf(b);
      if (i < 0) return;
      var to = { ArrowRight: list[(i + 1) % list.length], ArrowLeft: list[(i - 1 + list.length) % list.length], Home: list[0], End: list[list.length - 1] }[e.key];
      if (!to) return;
      e.preventDefault();
      var wasOpen = b.getAttribute("aria-expanded") === "true";
      closeMenus();
      menubarRove(bar, to);
      if (wasOpen) toggleMenu(to);
    });
    bar.addEventListener("pointerover", function (e) {
      var b = closestOf(e.target, "[data-kit-menu]");
      if (!b || b.getAttribute("aria-expanded") === "true" || menubarButtons(bar).indexOf(b) < 0) return;
      if (menubarButtons(bar).some(function (x) { return x.getAttribute("aria-expanded") === "true"; })) { closeMenus(); menubarRove(bar, b); toggleMenu(b); }
    });
  }

  // Navigation menu: <nav class="kit-navmenu" data-kit-navmenu aria-label="Main"><ul class="kit-navmenu__list"><li>
  // <button class="kit-navmenu__trigger" type="button" aria-expanded="false" aria-controls="P">Products</button>
  // <div class="kit-navmenu__panel" id="P" hidden>links</div></li>...</ul></nav>. A disclosure of links (no menu
  // roles: the links stay links). A click, Enter or Space opens one panel and closes the others; a pointer resting
  // on a trigger for 100 ms opens it, and leaving the nav closes it after 200 ms; Escape closes and goes back to
  // the trigger; the focus or a click leaving the nav closes it. ArrowLeft and ArrowRight move between triggers.
  function setupNavmenu(nav) {
    if (nav.kitNavmenu) return;
    nav.kitNavmenu = true;
    var triggers = function () { return Array.prototype.slice.call(nav.querySelectorAll(".kit-navmenu__trigger[aria-controls]")); };
    var timer = null, hoverAt = 0;
    var set = function (t, open) {
      triggers().forEach(function (x) { var on = open && x === t, p = document.getElementById(x.getAttribute("aria-controls")); x.setAttribute("aria-expanded", String(on)); if (p) p.hidden = !on; });
    };
    var later = function (fn, ms) { clearTimeout(timer); timer = setTimeout(fn, ms); };
    nav.addEventListener("click", function (e) {
      var t = closestOf(e.target, ".kit-navmenu__trigger");
      if (!t || !nav.contains(t)) return;
      clearTimeout(timer);
      // A click right after the pointer opened it keeps it open (the press that follows the rest).
      if (t.getAttribute("aria-expanded") === "true" && Date.now() - hoverAt < 500) return;
      set(t, t.getAttribute("aria-expanded") !== "true");
    });
    nav.addEventListener("keydown", function (e) {
      var open = triggers().filter(function (x) { return x.getAttribute("aria-expanded") === "true"; })[0];
      if (e.key === "Escape" && open) { escapeHandled(e); set(null, false); open.focus(); return; }
      var list = triggers(), i = list.indexOf(closestOf(e.target, ".kit-navmenu__trigger"));
      if (i < 0 || (e.key !== "ArrowRight" && e.key !== "ArrowLeft")) return;
      e.preventDefault();
      list[(i + (e.key === "ArrowRight" ? 1 : -1) + list.length) % list.length].focus();
    });
    nav.addEventListener("focusout", function (e) { if (!withinEl(nav, e)) set(null, false); });
    nav.addEventListener("pointerover", function (e) {
      if (e.pointerType === "touch") return;
      var t = closestOf(e.target, ".kit-navmenu__trigger");
      if (t && t.getAttribute("aria-expanded") !== "true") later(function () { hoverAt = Date.now(); set(t, true); }, 100);
      else clearTimeout(timer);
    });
    nav.addEventListener("pointerleave", function (e) { if (e.pointerType !== "touch") later(function () { set(null, false); }, 200); });
    document.addEventListener("click", function (e) { if (!nav.contains(e.target)) set(null, false); });
  }

  // Preview card: <a href="..." data-kit-preview="ID"> and <div class="kit-preview" id="ID" hidden> anywhere. A
  // pointer resting on the link for 600 ms, or the focus on it, shows the card under the link (above it when
  // there is no room); it stays while the pointer is on the card and goes 300 ms after the pointer left both, at
  // once on Escape, blur or scroll. The card only repeats what the link's page says: it is aria-hidden and holds no
  // controls, so nothing can be reached through it alone. Not for touch: a tap follows the link.
  function setupPreview(a) {
    if (a.kitPreview) return;
    var card = document.getElementById(a.getAttribute("data-kit-preview"));
    if (!card) return;
    a.kitPreview = true;
    card.setAttribute("aria-hidden", "true");
    var openT = null, closeT = null;
    var place = function () {
      var r = a.getBoundingClientRect(), s = card.style, gap = 8, edge = 8;
      s.position = "fixed"; s.left = "0px"; s.top = "0px"; card.hidden = false;
      var w = card.offsetWidth, h = card.offsetHeight;
      var below = r.bottom + gap + h <= window.innerHeight - edge || r.top - gap - h < edge;
      s.left = Math.round(Math.max(edge, Math.min(r.left, window.innerWidth - w - edge))) + "px";
      s.top = Math.round(below ? r.bottom + gap : r.top - gap - h) + "px";
    };
    var show = function (ms) { clearTimeout(closeT); clearTimeout(openT); openT = setTimeout(place, ms); };
    var hide = function (ms) { clearTimeout(openT); clearTimeout(closeT); closeT = setTimeout(function () { card.hidden = true; }, ms); };
    a.addEventListener("pointerenter", function (e) { if (e.pointerType !== "touch") show(600); });
    a.addEventListener("pointerleave", function (e) { if (e.pointerType !== "touch") hide(300); });
    card.addEventListener("pointerenter", function () { clearTimeout(closeT); });
    card.addEventListener("pointerleave", function () { hide(300); });
    a.addEventListener("focus", function () { show(600); });
    a.addEventListener("blur", function () { hide(0); });
    a.addEventListener("keydown", function (e) { if (e.key === "Escape" && !card.hidden) { escapeHandled(e); hide(0); } });
    window.addEventListener("scroll", function () { if (!card.hidden) hide(0); }, true);
  }

  // Meter: <div class="kit-meter" data-kit-meter data-value="72" aria-label="Disk used"> with data-min (0),
  // data-max (100), data-low, data-high, data-optimum and data-unit ("GB"): a measure in a known range (disk space,
  // a score), not the progress of a task. role="meter" with the values and a text ("72%", or "72 GB"), the bar
  // filled, and its tone as the native meter element judges it: the zone of data-optimum is ok, the next warn,
  // the far one error. A changed data-value draws again.
  function meterTone(v, lo, hi, opt) {
    if (isNaN(lo) && isNaN(hi)) return "";
    var zone = function (x) { return !isNaN(lo) && x < lo ? 0 : !isNaN(hi) && x > hi ? 2 : 1; };
    var d = Math.abs((isNaN(opt) ? 1 : zone(opt)) - zone(v));
    return ["ok", "warn", "error"][d];
  }
  function setupMeter(el) {
    var num = function (n, d) { var v = parseFloat(el.getAttribute("data-" + n)); return isNaN(v) ? d : v; };
    var min = num("min", 0), max = num("max", 100), v = Math.min(max, Math.max(min, num("value", min)));
    var share = max > min ? (v - min) / (max - min) : 0, unit = el.getAttribute("data-unit");
    el.setAttribute("role", "meter");
    el.setAttribute("aria-valuemin", String(min));
    el.setAttribute("aria-valuemax", String(max));
    el.setAttribute("aria-valuenow", String(v));
    el.setAttribute("aria-valuetext", unit ? v + " " + unit : Math.round(share * 100) + "%");
    var bar = el.querySelector(".kit-meter__bar");
    if (!bar) { bar = document.createElement("span"); bar.className = "kit-meter__bar"; el.appendChild(bar); }
    bar.style.width = (share * 100).toFixed(1) + "%";
    var tone = meterTone(v, num("low", NaN), num("high", NaN), num("optimum", NaN));
    el.classList.remove("kit-meter--ok", "kit-meter--warn", "kit-meter--error");
    if (tone) el.classList.add("kit-meter--" + tone);
  }

  // Toolbar: role="toolbar" with data-kit-toolbar is one tab stop. ArrowLeft and ArrowRight (ArrowUp and
  // ArrowDown with aria-orientation="vertical") move between its controls, round; Home and End go to the ends.
  // A disabled control stays reachable (aria-disabled). A text field, select or slider keeps its own arrow
  // keys, so it is best the last control (Tab leaves it). A part that moves its own focus (an icon bar) wins.
  function toolbarItems(bar) {
    return Array.prototype.filter.call(bar.querySelectorAll("button, a[href], input, select, textarea, [tabindex]"), function (c) {
      return !c.disabled && c.closest('[role="toolbar"]') === bar && !c.closest("[hidden], .kit-menu__list, .kit-popover");
    });
  }
  function ownsArrows(t) { return /^(input|textarea|select)$/.test(t.localName) && !/^(checkbox|radio|button|submit|reset|color|file)$/.test(t.type || ""); }
  function setupToolbar(bar) {
    if (bar.kitToolbar) return;
    bar.kitToolbar = true;
    var rove = function (cur) { toolbarItems(bar).forEach(function (c) { c.setAttribute("tabindex", c === cur ? "0" : "-1"); }); };
    var all = toolbarItems(bar);
    rove(all.filter(function (c) { return c.getAttribute("tabindex") === "0"; })[0] || all[0]);
    bar.addEventListener("focusin", function (e) { if (toolbarItems(bar).indexOf(e.target) >= 0) rove(e.target); });
    bar.addEventListener("keydown", function (e) {
      var l = toolbarItems(bar), i = l.indexOf(e.target);
      if (i < 0 || e.defaultPrevented || ownsArrows(e.target)) return;
      var vertical = bar.getAttribute("aria-orientation") === "vertical";
      var keys = {}; keys[vertical ? "ArrowDown" : "ArrowRight"] = (i + 1) % l.length; keys[vertical ? "ArrowUp" : "ArrowLeft"] = (i - 1 + l.length) % l.length; keys.Home = 0; keys.End = l.length - 1;
      if (!Object.prototype.hasOwnProperty.call(keys, e.key)) return;
      e.preventDefault();
      l[keys[e.key]].focus();
    });
  }

  // Select all: data-kit-checkall on a fieldset (or any group) of checkboxes, one of them
  // data-kit-checkall-parent. The parent is checked when all are and mixed (indeterminate) when some are; it
  // checks or clears them all, leaving a disabled one as it is. A group inside a group counts as one child
  // through its own parent. "kit:change" on the group with detail.values (the checked values).
  function setupCheckall(group) {
    if (group.kitCheckall) return;
    var parent = Array.prototype.filter.call(group.querySelectorAll("input[type=checkbox][data-kit-checkall-parent]"), function (c) { return c.closest("[data-kit-checkall]") === group; })[0];
    if (!parent) return;
    group.kitCheckall = true;
    var kids = function () {
      return Array.prototype.filter.call(group.querySelectorAll("input[type=checkbox]"), function (c) {
        if (c === parent) return false;
        var own = c.closest("[data-kit-checkall]");
        return own === group || (c.hasAttribute("data-kit-checkall-parent") && own.parentNode.closest("[data-kit-checkall]") === group);
      });
    };
    var off = function (c) { return c.disabled || !!c.closest('[aria-disabled="true"]'); };
    var sync = function () {
      var k = kids(), on = k.filter(function (c) { return c.checked && !c.indeterminate; }).length, part = k.some(function (c) { return c.indeterminate; });
      parent.checked = k.length > 0 && on === k.length;
      parent.indeterminate = !parent.checked && (on > 0 || part);
    };
    group.addEventListener("change", function (e) {
      if (e.target === parent) kids().forEach(function (c) {
        if (off(c) || (c.checked === parent.checked && !c.indeterminate)) return;
        c.checked = parent.checked; c.indeterminate = false;
        if (c.hasAttribute("data-kit-checkall-parent")) c.dispatchEvent(new Event("change", { bubbles: true }));
      });
      sync();
      if (e.target === parent || kids().indexOf(e.target) >= 0) emit(group, "change", { values: kids().filter(function (c) { return c.checked && !c.hasAttribute("data-kit-checkall-parent"); }).map(function (c) { return c.value; }) });
    });
    sync();
  }

  // F6 moves the focus into the newest toast (its first button) and F6 there goes back to where it was, so a
  // toast's action can be reached without the pointer; the toast waits while it has the focus.
  var toastBack = null;
  document.addEventListener("keydown", function (e) {
    if (e.key !== "F6" || e.ctrlKey || e.altKey || e.metaKey) return;
    var region = document.querySelector(".kit-toasts");
    if (!region) return;
    if (region.contains(document.activeElement)) { e.preventDefault(); focusBack(toastBack, null); toastBack = null; return; }
    var list = region.querySelectorAll(".kit-toast:not(.is-leaving)"), last = list[list.length - 1];
    if (!last) return;
    var to = last.querySelector("button");
    if (!to) { to = last; last.setAttribute("tabindex", "-1"); }
    e.preventDefault();
    toastBack = document.activeElement;
    to.focus();
  });

  // Context menu by touch: a long press (500 ms, a finger or pen moving less than 10 px) on a data-kit-context
  // area opens its menu at the press, for browsers that send no contextmenu then; the click after it is dropped.
  var press = null, dropClick = false;
  function pressEnd() { if (press) { clearTimeout(press.timer); press = null; } }
  document.addEventListener("pointerdown", function (e) {
    if (e.pointerType === "mouse") return;
    var area = contextArea(e.target);
    if (!area) return;
    var x = e.clientX, y = e.clientY;
    pressEnd();
    press = { x: x, y: y, id: e.pointerId, timer: setTimeout(function () {
      press = null;
      if (contextOpen() || !openContextMenu(area, x, y)) return;
      contextKeyAt = Date.now(); dropClick = true;
      setTimeout(function () { dropClick = false; }, 800);
    }, 500) };
  }, { passive: true });
  document.addEventListener("pointermove", function (e) { if (press && e.pointerId === press.id && Math.abs(e.clientX - press.x) + Math.abs(e.clientY - press.y) > 10) pressEnd(); }, { passive: true });
  ["pointerup", "pointercancel", "contextmenu"].forEach(function (t) { document.addEventListener(t, pressEnd, { passive: true }); });
  document.addEventListener("click", function (e) { if (dropClick) { dropClick = false; e.preventDefault(); e.stopPropagation(); } }, true);

  // The parts that need setting up, in what the page has now or writes later.
  var PARTS = [[".kit-tip[data-kit-tip], [data-kit-tip]", setupTip], ["select[data-kit-multi]", setupMulti], ["[data-kit-range]", setupRange], ["[data-kit-tree]", setupTree],
    ["[data-kit-iconbar]", setupIconbar], ["[data-kit-avatar]", setupAvatar], ["[data-kit-slider-range]", setupSliderRange], ["[data-kit-tags]", setupTags],
    ["[data-kit-board] > *", setupBoardCard], ["[data-kit-board]", setupBoardList], ["[data-kit-calendar]", function (el) { if (!el.kitCal) setupCalendar(el); }], ["[data-kit-cycle]", setupCycle],
    [".kit-avatars[aria-label], .kit-board[aria-label]", function (el) { if (!el.getAttribute("role")) el.setAttribute("role", "group"); }],
    // Also for what a page writes after it loaded (a search box in a panel drawn later).
    ["[data-kit-hold]", setupHold], ["[data-kit-search]", setupSearch], ["[data-kit-drop]", setupDrop], ["[data-kit-theme]", setupTheme],
    [".kit-tabs--animated", function (g) { setupSlider(g, ".kit-tab", "aria-selected", "kit-tabs__indicator"); }],
    [".kit-segmented--animated", function (g) { setupSlider(g, "button", "aria-pressed", "kit-segmented__indicator"); }],
    ['[role="tablist"], .kit-tabs', setupTablist], ["[data-kit-shell-menu]", setupShellMenu],
    ["[data-kit-tooltip]", setupTooltip], ["dialog[data-kit-palette]", setupPalette],
    ["[data-kit-listbox]", setupListbox], ["[data-kit-number]", setupNumber], ["[data-kit-password]", setupPassword], ["[data-kit-otp]", setupOtp],
    ["[data-kit-address]", setupAddress], ["[data-kit-daterange]", setupDateRange], ["dialog[data-kit-sheet]", setupSheet], ["[data-kit-carousel]", setupCarousel],
    ["[data-kit-reorder]", setupReorder], ["[data-kit-swipe]", setupSwipe], ["[data-kit-splitter]", setupSplitter], ["[data-kit-disclosure]", setupDisclosure],
    ["[data-kit-overflow]", setupOverflow], ["[data-kit-breadcrumbs]", setupCrumbs],
    ['.kit-menubar[role="menubar"]', setupMenubar], ["[data-kit-navmenu]", setupNavmenu], ["a[data-kit-preview]", setupPreview], ["[data-kit-meter]", setupMeter],
    ['[role="toolbar"][data-kit-toolbar]', setupToolbar], ["[data-kit-checkall]", setupCheckall]];
  function setupParts(root) {
    PARTS.forEach(function (p) {
      if (root.matches && root.matches(p[0])) safe(p[1], root);
      if (root.querySelectorAll) Array.prototype.forEach.call(root.querySelectorAll(p[0]), function (el) { safe(p[1], el); });
    });
    if (root.matches && root.matches(".kit-stamp, [data-kit-stamp], [data-kit-stamp-of]")) showStamp(root);
    if (root.querySelectorAll) Array.prototype.forEach.call(root.querySelectorAll(".kit-stamp, [data-kit-stamp], [data-kit-stamp-of]"), function (el) { showStamp(el); });
  }

  // Filling parts from data, so a page writes no DOM code of its own for them.
  // KitUI.options(select, values, { all: "All ITEMS", selected }) writes a select's options:
  // values are texts or { value, label }; "all" adds a first option with the value "" (no filter);
  // the current choice stays when it is still among the values. Returns the select.
  // An element given itself or by a selector.
  function elementOf(x) { return typeof x === "string" ? document.querySelector(x) : x; }
  function newOption(value, label) {
    var o = document.createElement("option");
    o.value = value;
    o.textContent = label;
    return o;
  }
  // One value as an option: a text, or { value, label }; null for a value that is not there.
  function optionOf(v) {
    var isObj = !!v && typeof v === "object";
    var val = isObj ? v.value : v;
    if (val === null || val === undefined) return null;
    return newOption(String(val), isObj && v.label !== undefined ? String(v.label) : String(val));
  }
  function fillOptions(select, values, opts) {
    var el = elementOf(select);
    if (!el) return el;
    opts = opts || {};
    var keep = opts.selected !== undefined ? String(opts.selected) : el.value;
    var frag = document.createDocumentFragment(), seen = {};
    if (opts.all !== undefined && opts.all !== false) { frag.appendChild(newOption("", opts.all)); seen[""] = true; }
    (values || []).forEach(function (v) {
      var o = optionOf(v);
      if (!o) return;
      seen[o.value] = true;
      frag.appendChild(o);
    });
    el.replaceChildren(frag);
    if (seen[keep]) el.value = keep; else if (el.options.length) el.selectedIndex = 0;
    return el;
  }
  // KitUI.fillTable(table, rows, columns?, { id, empty }) writes a table's body from a list of rows.
  // Without columns, the header cells say what goes in each column: <th data-key="COLUMN"> (the
  // row's field), class kit-num for numbers, data-format="number|percent|date" for how it shows.
  // A column given in code: { key, value: function (row), format: "number" | "percent" | "date" |
  // function (value, row), num: true, missing: "-" }. Numbers and dates get data-sort (the raw
  // value), so sorting is by value; opts.id names a field for each row's data-id (row selection).
  // The table's <tr data-kit-empty> row stays (one is made with opts.empty, or "Nothing to show",
  // when there is none) and shows when the list is empty. Sorting, paging and search follow the
  // new rows by themselves. Returns the number of rows written.
  function cellValue(c, row) { return typeof c.value === "function" ? c.value(row) : c.key ? row[c.key] : ""; }
  var CELL_FORMATS = { number: "number", percent: "percent", date: "date" };
  function isMissing(v) { return v === null || v === undefined || v === ""; }
  function cellText(c, v, row) {
    var f = c.format;
    if (typeof f === "function") return f(v, row);
    if (isMissing(v)) return c.missing !== undefined ? c.missing : "-";
    var named = Object.prototype.hasOwnProperty.call(CELL_FORMATS, f) ? CELL_FORMATS[f] : null;
    return named ? format[named](v) : String(v);
  }
  // A number column: marked num, formatted as a number or percentage, or (neither said) holding a number.
  function isNumCell(c, v) { return c.num || c.format === "number" || c.format === "percent" || (c.num === undefined && c.format == null && typeof v === "number"); }
  function fillCell(c, row) {
    var td = document.createElement("td");
    var v = cellValue(c, row);
    td.textContent = cellText(c, v, row);
    var isNum = isNumCell(c, v);
    if (isNum) td.className = "kit-num";
    if ((isNum && typeof v === "number") || c.format === "date") td.setAttribute("data-sort", v == null ? "" : String(v));
    return td;
  }
  // The last header row's cells, without the row selection's checkbox column.
  function headCells(t) {
    return t.tHead ? Array.prototype.slice.call(t.tHead.rows[t.tHead.rows.length - 1].cells).filter(function (th) { return !th.classList.contains("kit-table__select"); }) : [];
  }
  function headColumn(th) {
    return { key: th.getAttribute("data-key"), format: th.getAttribute("data-format") || (th.classList.contains("kit-num") ? "number" : null), num: th.classList.contains("kit-num") };
  }
  function newEmptyRow(span, text) {
    var empty = document.createElement("tr");
    empty.setAttribute("data-kit-empty", "");
    empty.innerHTML = '<td><div class="kit-empty"><p class="kit-empty__title"></p></div></td>';
    empty.cells[0].colSpan = Math.max(1, span);
    empty.querySelector(".kit-empty__title").textContent = text || "Nothing to show";
    return empty;
  }
  // One table row from a data row; idField names the field for data-id.
  function fillRow(row, cols, idField) {
    var tr = document.createElement("tr");
    if (idField && row && row[idField] != null) tr.setAttribute("data-id", String(row[idField]));
    cols.forEach(function (c) { tr.appendChild(fillCell(c, row)); });
    return tr;
  }
  // The body's rows replaced by frag, the empty row kept last.
  function replaceRows(body, frag, empty) {
    Array.prototype.slice.call(body.rows).forEach(function (r) { if (r !== empty) body.removeChild(r); });
    body.insertBefore(frag, body.firstChild);
    if (empty.parentNode !== body) body.appendChild(empty);
  }
  function fillTable(table, list, columns, opts) {
    var t = elementOf(table);
    if (!t) return 0;
    if (columns && !Array.isArray(columns)) { opts = columns; columns = null; }
    opts = opts || {};
    var rowsIn = list || [];
    var cols = columns || headCells(t).map(headColumn);
    var body = t.tBodies[0] || t.appendChild(document.createElement("tbody"));
    var empty = body.querySelector("tr[data-kit-empty]") || newEmptyRow(cols.length, opts.empty);
    var frag = document.createDocumentFragment();
    rowsIn.forEach(function (row) { frag.appendChild(fillRow(row, cols, opts.id)); });
    replaceRows(body, frag, empty);
    empty.hidden = rowsIn.length > 0;
    return rowsIn.length;
  }

  window.KitUI = {
    toast: toast,
    options: fillOptions,
    fillTable: fillTable,
    confirm: confirmBox,
    alert: alertBox,
    format: format,
    open: openPanel,
    close: closePanel,
    stamp: function (el, when) { showStamp(typeof el === "string" ? document.querySelector(el) : el, when); },
    range: function (preset) { return rangeOf(preset); },
    calendar: function (el, opts) { setupCalendar(typeof el === "string" ? document.querySelector(el) : el, opts || {}); },
    check: checkField,
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
    toastAlerts(region);
    return region;
  }
  // The alert region for error toasts, inside the toast stack (same corner, errors on top). Made empty
  // with the stack at start, so the first error is read out.
  function toastAlerts(region) {
    var alerts = region.querySelector(".kit-toasts__alerts");
    if (!alerts) {
      alerts = document.createElement("div");
      alerts.className = "kit-toasts__alerts";
      alerts.setAttribute("role", "alert");
      region.insertBefore(alerts, region.firstChild);
    }
    return alerts;
  }
  // Tabs (role="tablist"): the arrow keys, Home and End move between the tabs and select; one tab stop.
  function setupTablist(group) {
    if (group.kitTabs) return;
    group.kitTabs = true;
    var tabs = function () { return Array.prototype.slice.call(group.querySelectorAll('[role="tab"], .kit-tab')); };
    var roving = function () { var list = tabs(), cur = list.filter(function (b) { return b.getAttribute("aria-selected") === "true"; })[0] || list[0]; list.forEach(function (b) { b.setAttribute("tabindex", b === cur ? "0" : "-1"); }); };
    // Tab panels: when every tab names its panel (aria-controls="ID"), the selected tab's panel shows
    // and the others are hidden, with role="tabpanel" and aria-labelledby; "kit:tab" with detail.tab,
    // panel, value (data-value, else the panel id) and text. Charts in a panel draw when it shows.
    var panelOf = function (b) { var id = b.getAttribute("aria-controls"); return id ? document.getElementById(id) : null; };
    var withPanels = function () { var list = tabs(); return list.length > 0 && list.every(panelOf); };
    var show = function (sel, notify) {
      if (!sel || !withPanels()) return;
      tabs().forEach(function (b) {
        var on = b === sel, p = panelOf(b);
        b.setAttribute("aria-selected", on ? "true" : "false");
        if (!b.id) b.id = p.id + "-tab";
        p.setAttribute("role", "tabpanel");
        p.setAttribute("aria-labelledby", b.id);
        if (!p.hasAttribute("tabindex")) p.setAttribute("tabindex", "0");
        p.hidden = !on;
      });
      if (notify) group.dispatchEvent(new CustomEvent("kit:tab", { bubbles: true, detail: { tab: sel, panel: panelOf(sel), value: sel.getAttribute("data-value") || sel.getAttribute("aria-controls"), text: sel.textContent.trim() } }));
    };
    if (withPanels()) { var first = tabs(); show(first.filter(function (b) { return b.getAttribute("aria-selected") === "true"; })[0] || first[0], false); }
    group.addEventListener("click", function (e) {
      var b = e.target && e.target.closest ? e.target.closest('[role="tab"], .kit-tab') : null;
      if (b && group.contains(b) && !b.disabled) show(b, true);
    });
    group.addEventListener("keydown", function (e) {
      var list = tabs(), i = list.indexOf(document.activeElement);
      if (i < 0) return;
      var n = e.key === "ArrowRight" ? (i + 1) % list.length : e.key === "ArrowLeft" ? (i - 1 + list.length) % list.length : e.key === "Home" ? 0 : e.key === "End" ? list.length - 1 : -1;
      if (n < 0) return;
      e.preventDefault();
      list[n].focus();
      // data-activation="manual": the arrow keys only move the focus; Enter or Space selects (a large panel
      // that is slow to draw is then not drawn for every tab passed on the way).
      if (group.getAttribute("data-activation") !== "manual") { list[n].click(); roving(); }
      else tabs().forEach(function (b) { b.setAttribute("tabindex", b === list[n] ? "0" : "-1"); });
    });
    group.addEventListener("click", function () { setTimeout(roving, 0); });
    roving();
  }
  // A part that fails to set up (odd markup) does not stop the parts after it.
  function safe(fn, el) { try { fn(el); } catch (e) { if (window.console) console.error("UI kit: a part could not be set up", el, e); } }
  function startKit() {
    safe(setupGuard);
    toastRegion();
    fillBars(document);
    setupParts(document);
    // Bars and tables a script writes after the page loaded (a dashboard drawn from its data).
    if (window.MutationObserver) {
      new MutationObserver(function (list) {
        list.forEach(function (m) {
          if (m.type === "attributes") {
            fillBars(m.target);
            if (/^data-kit-(sort|pages)$/.test(m.attributeName)) setupTables(m.target);
            if (m.attributeName === "data-value" && m.target.matches && m.target.matches("[data-kit-meter]")) safe(setupMeter, m.target);
          }
          else if (m.type === "characterData") { var row = m.target.parentElement && m.target.parentElement.closest("tr, li"); if (row) fillBars(row); }
          else {
            Array.prototype.forEach.call(m.addedNodes, function (n) { if (n.nodeType === 1) { fillBars(n); setupTables(n); setupParts(n); } });
            // A percentage written next to a bar (a cell filled after its row) fills that row's bars.
            var near = m.target.closest && m.target.closest("tr, li");
            if (near) fillBars(near);
          }
        });
      }).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ["aria-valuenow", "aria-valuemin", "aria-valuemax", "data-value", "data-kit-sort", "data-kit-pages"] });
    }
    setupTables(document);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startKit); else startKit();
})();
