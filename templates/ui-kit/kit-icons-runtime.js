/* Draws the icons: every element with data-kit-icon="NAME" gets that Lucide icon as an inline SVG
   in the current text colour (also elements added later). An element with aria-label becomes an
   image with that name; otherwise the icon is hidden from screen readers. KitIcons.svg(NAME) gives
   the markup for code. Works from file:// (no sprite file to load). */
(function () {
  "use strict";
  var data = window.KitIconData || {};
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function svg(name, label) {
    var inner = data[name];
    if (!inner) return "";
    return '<svg class="kit-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"' +
      (label ? ' role="img" aria-label="' + esc(label) + '"' : ' aria-hidden="true" focusable="false"') + ">" + inner + "</svg>";
  }
  function paint(root) {
    var list = (root && root.querySelectorAll) ? root.querySelectorAll("[data-kit-icon]") : [];
    Array.prototype.forEach.call(list, function (el) {
      var name = el.getAttribute("data-kit-icon");
      if (el.getAttribute("data-kit-icon-drawn") === name) return;
      el.innerHTML = svg(name);
      el.setAttribute("data-kit-icon-drawn", name);
      if (el.getAttribute("aria-label") && !el.getAttribute("role")) el.setAttribute("role", "img");
    });
    if (root && root.getAttribute && root.hasAttribute("data-kit-icon")) paint({ querySelectorAll: function () { return [root]; } });
  }
  window.KitIcons = { svg: svg, paint: paint, names: function () { return Object.keys(data); } };
  function startIcons() {
    paint(document);
    if (window.MutationObserver) new MutationObserver(function (records) {
      records.forEach(function (r) {
        if (r.type === "attributes") paint({ querySelectorAll: function () { return [r.target]; } });
        Array.prototype.forEach.call(r.addedNodes, function (n) { if (n.nodeType === 1) paint(n); });
      });
    }).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-kit-icon"] });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", startIcons); else startIcons();
})();
