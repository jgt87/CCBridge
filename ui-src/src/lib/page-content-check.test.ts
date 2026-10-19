// @vitest-environment jsdom
// The page check (lib/page-content-check.js) on a page that has one of each problem, and on a clean
// one: every kind it reports, in order, with its text. jsdom has no layout, so boxes come from
// data-w / data-h (100 x 50 when not given) and innerText is the text content.
import fs from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const repo = path.resolve(import.meta.dirname, "../../..");
const pageCheck = fs.readFileSync(path.join(repo, "lib/page-content-check.js"), "utf8");
const run = async () => JSON.parse(await (new Function("return (\n" + pageCheck + "\n)")() as Promise<string>)) as { kind: string; text?: string; classes?: string[] }[];

const size = (el: Element, name: string, fallback: number) => {
  const v = el.getAttribute(name);
  return v === null ? fallback : Number(v);
};
const saved = {
  rects: Element.prototype.getClientRects,
  box: Element.prototype.getBoundingClientRect,
  width: Object.getOwnPropertyDescriptor(Element.prototype, "clientWidth"),
};
beforeAll(() => {
  Element.prototype.getClientRects = function () { return [{}] as unknown as DOMRectList; };
  Element.prototype.getBoundingClientRect = function () {
    const w = size(this, "data-w", 100), h = size(this, "data-h", 50);
    return { x: 0, y: 0, left: 0, top: 0, right: w, bottom: h, width: w, height: h, toJSON: () => ({}) } as DOMRect;
  };
  Object.defineProperty(HTMLElement.prototype, "clientWidth", { configurable: true, get() { return size(this, "data-w", 100); } });
  Object.defineProperty(HTMLElement.prototype, "innerText", { configurable: true, get() { return this.textContent; } });
});
afterAll(() => {
  Element.prototype.getClientRects = saved.rects;
  Element.prototype.getBoundingClientRect = saved.box;
  delete (HTMLElement.prototype as unknown as Record<string, unknown>).clientWidth;
  delete (HTMLElement.prototype as unknown as Record<string, unknown>).innerText;
});

// An e with an accent written as UTF-8 and read as Windows-1252, and what it should be; built from
// code points, since the repository scan reports such characters written in a file.
const broken = String.fromCharCode(0xc3, 0xa9), accented = String.fromCharCode(0xe9);

describe("page check: what the page shows", () => {
  it("reports each kind of problem in its order, with its text", async () => {
    document.head.innerHTML = "";
    document.body.innerHTML =
      "<p>Caf" + broken + " au lait</p>" +
      '<div class="kit-notice--error">Data did not load</div>' +
      '<div data-kit-chart="bar"></div>' +
      '<div data-kit-chart="ring" data-kit-shape-error>Expected a list of items</div>' +
      "<table><caption>Empty list</caption><thead><tr><th>Name</th></tr></thead><tbody></tbody></table>" +
      "<table><caption>People</caption><thead><tr><th>Name</th><th>Share</th><th>Joined</th><th>Bar</th></tr></thead><tbody>" +
      '<tr><td>Ann</td><td>40%</td><td>2026-07-16</td><td><div data-w="200" data-h="10" style="padding: 0; background: #eee"><div data-w="100" data-h="10" style="background: red"></div></div></td></tr>' +
      "<tr><td>Bob</td><td>10%</td><td>16 Jul 26</td><td></td></tr>" +
      "<tr><td>Cy</td><td>20%</td><td>2026-07-18</td><td></td></tr>" +
      "</tbody></table>" +
      '<div>&lt;div class="x"&gt;hello&lt;/div&gt;</div>' +
      "<div>then call document.getElementById('x') here</div>" +
      '<div style="cursor: pointer">Open details</div>' +
      '<span id="lost" <b>gone</b></span>';
    const out = await run();
    expect(out.map((f) => f.kind)).toEqual(["encoding", "bar", "empty", "error", "empty", "error", "sort", "leak", "leak", "leak", "keyboard", "date", "date", "kitcss"]);
    expect(out[0].text).toBe("shows broken characters, UTF-8 text read as Windows-1252: '" + broken + "' should be '" + accented + "' (in 'Caf" + broken + " au lait'); the text itself is broken in the file or the data: write the real characters and read and write files as UTF-8");
    expect(out.slice(1)).toMatchInlineSnapshot(`
      [
        {
          "kind": "bar",
          "text": "bars in 'People' do not show their percentage (1 of 1 rows): 'Ann' shows 40% but its bar is 50% full: a bar next to a percentage fills exactly that share of its track (width: PERCENT%), not scaled to the largest row",
        },
        {
          "kind": "empty",
          "text": "chart 'chart 1' shows nothing: no chart was drawn (a declared kit chart: data-kit-chart "bar" with data-kit-data). Make the chart draw with the data the page has (check the data you pass it and that styles/kit/kit-charts.js is loaded; KitCharts.bar(element, data) draws one from code). A kit-empty message is only for when there is no data to show, written by your code in that case; never replace a chart with a fixed empty state",
        },
        {
          "kind": "error",
          "text": "chart 'chart 2' was given its data in a shape it does not read: Expected a list of items",
        },
        {
          "kind": "empty",
          "text": "table 'Empty list' has no rows and no empty state: check the data it gets, and add a row with data-kit-empty that says what is missing",
        },
        {
          "kind": "error",
          "text": "shows an error message: 'Data did not load': find out why (often the data did not load or has another shape) and fix it",
        },
        {
          "kind": "sort",
          "text": "table 'People' (3 rows) cannot be sorted: clicking its column headers does not reorder the rows; make every column sortable (with the UI kit: data-kit-sort on the table, th.kit-num for numbers)",
        },
        {
          "kind": "leak",
          "text": "shows HTML markup as plain text: '<div class="x">hello</div>': the tags are written with entities in the page, a tag lost its <, or a script gives markup to textContent/innerText (use innerHTML, or build the elements); the file check names the line",
        },
        {
          "kind": "leak",
          "text": "shows script code as plain text: 'then call document.getElementById('x') here': the <script> tag around that code is missing or damaged, so put <script> ... </script> around it; the file check names the line",
        },
        {
          "kind": "leak",
          "text": "the <span> tag (inside #lost) has no >: the browser read what followed it ('<b') as attributes, so that text or tag is not on the page (a script tag there never loaded); close the tag with >, the file check names the line",
        },
        {
          "kind": "keyboard",
          "text": "has 1 clickable part a keyboard cannot reach (a pointer cursor, a click handler or role="button" on something that is not a button, link or focusable): <div> 'Open details': make each a <button> (or give it role="button", tabindex="0" and the same action on Enter and Space); with the UI kit, tables sort with data-kit-sort and charts filter with "selectable"",
        },
        {
          "kind": "date",
          "text": "shows 2 dates in ISO form (such as '2026-07-16' in 'People'): people read day month year (16 Jul 2026): format dates for display (with the UI kit KitUI.format.date(iso)) and keep the ISO value in data-sort",
        },
        {
          "kind": "date",
          "text": "shows 1 date with a two-digit year (such as '16 Jul 26'): write the full year (16 Jul 2026; with the UI kit KitUI.format.date)",
        },
        {
          "classes": [
            "kit-notice--error",
          ],
          "kind": "kitcss",
        },
      ]
    `);
  });
  it("reports markup shown as text in a paragraph or a link too, not only in a div", async () => {
    document.head.innerHTML = "";
    const leaks = async (html: string) => {
      document.body.innerHTML = html;
      return (await run()).filter((f) => f.kind === "leak").map((f) => f.text ?? "");
    };
    expect(await leaks('<p>&lt;span class="total"&gt;12&lt;/span&gt;</p>')).toEqual([expect.stringContaining('<span class="total">12</span>')]);
    expect(await leaks('<a href="#x">&lt;b&gt;More details&lt;/b&gt;</a>')).toEqual([expect.stringContaining("<b>More details</b>")]);
    // A code sample stays a code sample.
    expect(await leaks("<pre>&lt;div&gt;sample&lt;/div&gt;</pre>")).toEqual([]);
  });
  it("reports nothing on a clean page", async () => {
    document.head.innerHTML = "";
    document.body.innerHTML = "<h1>Hello</h1><p>A plain page with 1,250 visitors on 16 Jul 2026.</p>";
    expect(await run()).toEqual([]);
  });
});
