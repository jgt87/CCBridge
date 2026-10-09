// Page check at phone width (Agent Test-WebPageCore sets a 375 px wide window first): does the page
// scroll sideways, and which parts make it do so. Returns "" or one sentence.
(() => {
  const de = document.documentElement, w = de.clientWidth, over = de.scrollWidth - w;
  if (over <= 2) return "";
  // A part inside a box that scrolls or clips by itself (a kit-table-wrap) does not widen the page.
  const inScroller = (el) => {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      if (/(auto|scroll|hidden|clip)/.test(getComputedStyle(p).overflowX)) return true;
    }
    return false;
  };
  const wide = [...document.body.querySelectorAll("*")].filter((el) => {
    const r = el.getBoundingClientRect();
    if (!r.width || r.right <= w + 2) return false;
    const s = getComputedStyle(el);
    return s.position !== "fixed" && s.visibility !== "hidden" && !inScroller(el);
  });
  // The parts that cause it: wide ones without a wide part inside.
  const causes = wide.filter((el) => !wide.some((o) => o !== el && el.contains(o))).slice(0, 4);
  const own = (el) => el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") + (el.classList.length ? "." + [...el.classList].slice(0, 2).join(".") : "");
  const name = (el) => {
    if (el.id || el.classList.length) return own(el);
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) if (p.id || p.classList.length) return own(el) + " in " + own(p);
    return own(el);
  };
  return "at phone width (" + w + " px) the page scrolls sideways by " + over + " px" +
    (causes.length ? ": " + causes.map((el) => name(el) + " (" + Math.round(el.getBoundingClientRect().width) + " px wide)").join(", ") : "") +
    "; let it wrap or shrink (a wide table goes in a kit-table-wrap, which scrolls by itself)";
})()
