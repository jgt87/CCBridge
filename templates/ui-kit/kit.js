/*
  UI kit behaviour for plain pages (no build step, works from file://). Load after the page's
  markup: <script src="styles/kit/kit.js"></script>. Each part starts on its data-kit-* attribute
  and reports through a DOM event, so page code listens instead of editing this file.
  Behaviour adapted from kokonutui (MIT licence, see LICENSE-kokonutui.txt; https://kokonutui.com):
  hold-button, action-search-bar, file-upload, smooth-tab.
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

  function startKit() {
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-hold]"), setupHold);
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-search]"), setupSearch);
    Array.prototype.forEach.call(document.querySelectorAll("[data-kit-drop]"), setupDrop);
    Array.prototype.forEach.call(document.querySelectorAll(".kit-tabs--animated"), function (g) { setupSlider(g, ".kit-tab", "aria-selected", "kit-tabs__indicator"); });
    Array.prototype.forEach.call(document.querySelectorAll(".kit-segmented--animated"), function (g) { setupSlider(g, "button", "aria-pressed", "kit-segmented__indicator"); });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startKit); else startKit();
})();
