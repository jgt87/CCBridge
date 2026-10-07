// Runs in the page check's tab right after the screenshot (lib/ShotDiff.psm1 Get-PageLayoutScript):
// where the page's recognisable parts are in the screenshot, so a changed area can be named in words
// (Find-RegionParts). Only the visible parts, in screenshot pixels; at most 400. Returns JSON.
(() => {
  const W = window.innerWidth, H = window.innerHeight;
  const sel = 'h1,h2,h3,h4,h5,h6,header,nav,main,footer,aside,section,article,form,table,dialog,fieldset,'
    + 'button,a[href],input,select,textarea,label,img,svg,canvas,video,figure,ul,ol,'
    + '[id],[role],[aria-label],[class*="card"],[class*="chart"],[class*="panel"],[class*="kit-"]';
  const clean = (t) => (t || '').replace(/\s+/g, ' ').trim();
  const out = [];
  for (const el of document.querySelectorAll(sel)) {
    if (out.length >= 400) break;
    const r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4 || r.right <= 0 || r.bottom <= 0 || r.left >= W || r.top >= H) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none' || Number(cs.opacity) === 0) continue;
    const tag = el.tagName.toLowerCase();
    let name = tag;
    if (el.id) name += '#' + el.id;
    else if (typeof el.className === 'string' && el.className.trim()) name += '.' + el.className.trim().split(/\s+/)[0];
    let text = clean(el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title') || '');
    if (!text && /^(h[1-6]|button|a|label|legend|summary|th|caption)$/.test(tag)) text = clean(el.innerText);
    if (!text && /^(input|select|textarea)$/.test(tag)) text = clean(el.getAttribute('placeholder') || el.getAttribute('name') || '');
    if (!text && /^(section|article|form|aside|nav|fieldset|dialog|figure)$/.test(tag)) {
      const h = el.querySelector('h1,h2,h3,h4,h5,h6,legend,figcaption,caption');
      if (h) text = clean(h.innerText);
    }
    out.push({ name, text: text.slice(0, 40), heading: /^h[1-6]$/.test(tag),
      x: Math.max(0, Math.round(r.left)), y: Math.max(0, Math.round(r.top)),
      w: Math.round(Math.min(r.right, W) - Math.max(0, r.left)), h: Math.round(Math.min(r.bottom, H) - Math.max(0, r.top)) });
  }
  return JSON.stringify(out);
})()
