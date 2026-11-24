// @vitest-environment jsdom
// The UI kit's page behaviour (templates/ui-kit/kit.js) and charts (kit-charts.js) in a browser-like
// document: tables, search, the parts' accessibility, and what a chart does with odd data.
import fs from "node:fs";
import path from "node:path";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
// The kit's scripts imported as text (Vite ?raw), not read from disk: an import is how code-health
// tools pair a test with the file it tests. Each script runs below as a page runs it.
import kitJs from "../../../templates/ui-kit/kit.js?raw";
import chartsJs from "../../../templates/ui-kit/kit-charts.js?raw";
import iconsRuntimeJs from "../../../templates/ui-kit/kit-icons-runtime.js?raw";
import pageCheckJs from "../../../lib/page-content-check.js?raw";

function load(code: string) {
  // The kit's scripts set up what the page has when they load; run them against this document.
  new Function(code)();
}
// The kit sets up parts a page writes later through a MutationObserver, which runs after the
// current task: wait for it (the scripts run once per document, so later tests rely on it).
const tick = () => new Promise((r) => setTimeout(r, 0));

type KitWindow = Window & { KitUI: { toast: (t: string) => HTMLElement }; KitCharts: Record<string, (host: HTMLElement, data: unknown) => void> };
const w = window as unknown as KitWindow;

async function table(rows: string[][], attrs = "data-kit-sort", head = ["Name", "Amount"], numCols = [1]) {
  document.body.innerHTML = `<input class="kit-input" data-kit-filter="t" aria-label="Search">
    <table class="kit-table" id="t" ${attrs}><thead><tr>${head.map((h, i) => `<th${numCols.includes(i) ? ' class="kit-num"' : ""}>${h}</th>`).join("")}</tr></thead>
    <tbody>${rows.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join("")}</tr>`).join("")}<tr data-kit-empty hidden><td colspan="2">Nothing matches</td></tr></tbody></table>`;
  const t = document.getElementById("t") as HTMLTableElement & { kitFilter: (q: string) => void };
  load(kitJs);
  await tick();
  return t;
}
const shown = (t: HTMLTableElement) => Array.from(t.tBodies[0].rows).filter((r) => !r.hidden && !r.hasAttribute("data-kit-empty")).map((r) => r.cells[0].textContent);
const sortBy = (t: HTMLTableElement, col: number) => (t.tHead!.rows[0].cells[col].querySelector("button") as HTMLButtonElement).click();

describe("kit.js tables", () => {
  beforeAll(() => {
    // Layout is not measured in jsdom; the tip positioning reads it defensively.
    Object.defineProperty(window, "innerWidth", { value: 1024, configurable: true });
  });
  it("searches on whitespace-separated words, every word must match", async () => {
    const t = await table([["Central", "1"], ["Harbour station", "2"], ["Park", "3"]]);
    expect(document.querySelector(".kit-toasts")).not.toBeNull();   // the live region is on the page before the first toast
    expect(document.querySelector(".kit-toasts > .kit-toasts__alerts[role=alert]")).not.toBeNull();   // and the alert region for errors
    t.kitFilter("harbour station");
    expect(shown(t)).toEqual(["Harbour station"]);
    t.kitFilter("sales");
    expect(shown(t)).toEqual([]);
    expect((t.querySelector("[data-kit-empty]") as HTMLTableRowElement).hidden).toBe(false);
    t.kitFilter("");
    expect(shown(t).length).toBe(3);
    expect((t.querySelector("[data-kit-empty]") as HTMLTableRowElement).hidden).toBe(true);
  });
  it("sorts numbers as people write them, and puts what is not a number last", async () => {
    const t = await table([["a", "41,7%"], ["b", "100%"], ["c", "12,5%"], ["d", "n/a"], ["e", ""]]);
    sortBy(t, 1);
    expect(shown(t)).toEqual(["c", "a", "b", "d", "e"]);
    sortBy(t, 1);
    expect(shown(t)).toEqual(["b", "a", "c", "d", "e"]);
  });
  it("reads thousands separators, decimal commas, parentheses and currency", async () => {
    const t = await table([["a", "5.210"], ["b", "999"], ["c", "1.234"]]);
    sortBy(t, 1);
    expect(shown(t)).toEqual(["b", "c", "a"]);
    const u = await table([["a", "$1,234.50"], ["b", "(1,234)"], ["c", "99.9"]]);
    sortBy(u, 1);
    expect(shown(u)).toEqual(["b", "c", "a"]);
    const v = await table([["a", "1.234,56"], ["b", "999,5"], ["c", "12"]]);
    sortBy(v, 1);
    expect(shown(v)).toEqual(["c", "b", "a"]);
  });
  it("does not run twice when the script is loaded twice", async () => {
    document.body.innerHTML = '<div class="kit-menu"><button data-kit-menu aria-expanded="false" type="button">Actions</button><div class="kit-menu__list" hidden><button class="kit-menu__item" type="button">Edit</button></div></div>';
    load(kitJs);
    load(kitJs);
    await tick();
    (document.querySelector("[data-kit-menu]") as HTMLButtonElement).click();
    expect(document.querySelector("[data-kit-menu]")!.getAttribute("aria-expanded")).toBe("true");
    expect((document.querySelector(".kit-menu__list") as HTMLElement).hidden).toBe(false);
  });
  it("gives named groups a role, a combo box its ARIA, and tabs the arrow keys", async () => {
    document.body.innerHTML = `<div class="kit-tags" data-kit-tags aria-label="Tags"></div>
      <div class="kit-search" data-kit-search><input class="kit-input" aria-label="Find"><ul class="kit-search__list"><li class="kit-search__item">One</li><li class="kit-search__item">Two</li></ul></div>
      <div class="kit-tabs" role="tablist"><button class="kit-tab" role="tab" aria-selected="true" type="button">A</button><button class="kit-tab" role="tab" aria-selected="false" type="button">B</button></div>
      <div class="kit-toasts-anchor"></div>`;
    load(kitJs);
    await tick();
    expect(document.querySelector(".kit-tags")!.getAttribute("role")).toBe("group");
    const input = document.querySelector(".kit-search input") as HTMLInputElement;
    expect(input.getAttribute("role")).toBe("combobox");
    expect(input.getAttribute("aria-controls")).toBe(document.querySelector(".kit-search__list")!.id);
    const tabs = Array.from(document.querySelectorAll<HTMLButtonElement>(".kit-tab"));
    expect(tabs.map((b) => b.getAttribute("tabindex"))).toEqual(["0", "-1"]);
    tabs[0].focus();
    tabs[0].dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
    expect(document.activeElement).toBe(tabs[1]);
  });
});

describe("kit-charts.js", () => {
  const host = () => {
    document.body.innerHTML = '<div class="kit-chart" id="c"></div><div class="kit-chart" id="d"></div>';
    load(chartsJs);
    return [document.getElementById("c")!, document.getElementById("d")!];
  };
  it("writes a ring's centre number like its legend, and a legend that reads with spaces even without styles", () => {
    const [c] = host();
    document.documentElement.lang = "en";
    w.KitCharts.ring(c, { items: [{ label: "Low", value: 1375 }, { label: "Medium", value: 11 }], center: 1386, legend: "values" });
    expect(c.querySelector(".kit-chart__center")!.textContent).toBe("1,386");
    const li = c.querySelector(".kit-chart__legend--values li")!;
    expect(li.textContent!.trim()).toBe("Low 1,375 99.2%");
  });
  it("draws a line through a missing value and gives a chart below zero an axis below zero", () => {
    const [c] = host();
    w.KitCharts.line(c, { labels: ["Jan", "Feb", "Mar", "Apr"], series: [{ name: "A", values: [3, "n/a", 5, -2] }] });
    const d = c.querySelector(".kit-chart__path")!.getAttribute("d")!;
    expect(d).not.toContain("NaN");
    expect(d.split("M").length - 1).toBe(2);   // two runs: before and after the gap
    expect(Array.from(c.querySelectorAll(".kit-chart__label")).some((l) => l.textContent === "-2" || l.textContent === "-5")).toBe(true);
    expect(c.querySelector(".kit-chart__table")!.textContent).toContain("-");
  });
  it("shows an empty state instead of a broken drawing, and one bad chart leaves the next alone", () => {
    const [c, d] = host();
    w.KitCharts.line(c, { labels: ["Jan"], series: [{ name: "A", values: [] }] });
    expect(c.querySelector(".kit-empty")).not.toBeNull();
    w.KitCharts.ring(c, { items: [] });
    expect(c.querySelector(".kit-empty")).not.toBeNull();
    w.KitCharts.area(c, { labels: ["a", "b"], series: "wrong" as unknown as [] });
    expect(c.querySelector(".kit-empty")!.textContent).toMatch(/could not be drawn|Nothing/);
    w.KitCharts.bar(d, { labels: ["a", "b"], series: [{ name: "S", values: [1, 2] }] });
    expect(d.querySelectorAll(".kit-chart__bar").length).toBe(2);
  });
  it("takes a colour by meaning on a gauge, and makes a selectable chart a group", () => {
    const [c, d] = host();
    w.KitCharts.gauge(c, { value: 72, color: "ok" });
    expect(Array.from(c.querySelectorAll("path")).some((p) => p.getAttribute("stroke") === "var(--kit-ok)")).toBe(true);
    w.KitCharts.bar(d, { labels: ["a", "b"], series: [{ name: "S", values: [1, 2] }], selectable: true });
    expect(d.querySelector("svg")!.getAttribute("role")).toBe("group");
    expect(d.querySelectorAll('[role="button"]').length).toBeGreaterThan(0);
  });
  it("shortens long labels of horizontal bars and keeps the whole in a title", () => {
    const [c] = host();
    Object.defineProperty(c, "clientWidth", { value: 300, configurable: true });
    w.KitCharts.bar(c, { horizontal: true, labels: ["Market square station entrance north side"], series: [{ name: "S", values: [4] }] });
    const label = c.querySelector(".kit-chart__label")!;
    expect(label.firstChild!.textContent!.length).toBeLessThan(30);   // the text node; the <title> holds the whole name
    expect(label.querySelector("title")!.textContent).toBe("Market square station entrance north side");
  });
  it("rounds only the top of a stack, fills an area per run, draws one item as a whole ring and shortens big numbers", () => {
    const [c, d] = host();
    w.KitCharts.bar(c, { labels: ["Mon"], series: [{ name: "A", values: [3] }, { name: "B", values: [2] }], stacked: true });
    const ds = Array.from(c.querySelectorAll(".kit-chart__bar")).map((b) => b.getAttribute("d")!);
    expect(ds.map((x) => x.includes("A"))).toEqual([false, true]);
    w.KitCharts.area(d, { labels: ["a", "b", "c", "d", "e"], series: [{ name: "S", values: [1, 2, null, 3, 4] }] });
    expect(d.querySelector(".kit-chart__area")!.getAttribute("d")!.split("Z").length - 1).toBe(2);
    expect(d.querySelector("linearGradient")).not.toBeNull();
    w.KitCharts.ring(c, { items: [{ label: "Only", value: 5 }, { label: "None", value: 0 }] });
    expect(c.querySelectorAll("circle.kit-chart__arc").length).toBe(1);
    w.KitCharts.gauge(d, { value: 25000, max: 100000 });
    expect(d.querySelector(".kit-chart__center")!.textContent).toBe("25k");
  });
  it("shows a dot and the values where the mouse is on a line chart", () => {
    const [c] = host();
    w.KitCharts.line(c, { labels: ["a", "b"], series: [{ name: "S", values: [1, 2] }, { name: "T", values: [null, 3] }] });
    const svg = c.querySelector("svg")!;
    svg.getBoundingClientRect = () => ({ left: 0, top: 0, width: 600, height: 260 }) as DOMRect;
    const hit = svg.querySelector('rect[fill="transparent"]')!;
    hit.dispatchEvent(new MouseEvent("mousemove", { clientX: 10 }));
    const dots = Array.from(c.querySelectorAll("circle.kit-chart__dot")).map((x) => x.getAttribute("visibility"));
    expect(dots).toEqual(["visible", "hidden"]);
    expect(c.querySelector(".kit-chart__tip")!.textContent).toBe("aS: 1T: -");
    // Pointer events too, so touch and pen read the values.
    hit.dispatchEvent(new MouseEvent("pointerleave"));
    expect(Array.from(c.querySelectorAll("circle.kit-chart__dot")).map((x) => x.getAttribute("visibility"))).toEqual(["hidden", "hidden"]);
    hit.dispatchEvent(new MouseEvent("pointermove", { clientX: 590 }));
    expect(Array.from(c.querySelectorAll("circle.kit-chart__dot")).map((x) => x.getAttribute("visibility"))).toEqual(["visible", "visible"]);
  });
});

type KitFormat = { number: (v: unknown, o?: { decimals?: number }) => string; percent: (v: unknown, d?: number) => string; date: (v: unknown, o?: { time?: boolean }) => string; relative: (v: unknown) => string };
type KitTable = HTMLTableElement & { kitSelected: () => HTMLTableRowElement[]; kitSelect: (on: boolean) => void };

describe("kit.js additions", () => {
  it("writes a data stamp as the time alone today, the date first on another day, and no empty brackets", async () => {
    await table([["a", "1"]]);
    const kit = (w as unknown as { KitUI: { stamp: (el: Element, when?: string) => void } }).KitUI;
    vi.useFakeTimers({ now: new Date(2026, 10, 16, 15, 0, 0) });
    try {
      document.body.innerHTML = '<span id="s1" class="kit-stamp"></span><span id="s2" class="kit-stamp" data-kit-prefix="Prices from"></span>';
      const s1 = document.getElementById("s1")!, s2 = document.getElementById("s2")!;
      kit.stamp(s1, new Date(2026, 10, 16, 14, 0, 0).toISOString());
      expect(s1.textContent).toMatch(/^Data as of [^,]*\b(14:00|2:00\s?PM)\b \(1 hour ago\)$/);   // no date: it is today
      kit.stamp(s2, new Date(2026, 10, 13, 9, 30, 0).toISOString());
      expect(s2.textContent).toMatch(/^Prices from .*2026.* \(3 days ago\)$/);
      expect(s2.getAttribute("title")).toBe(new Date(2026, 10, 13, 9, 30, 0).toISOString());
      // A browser without relative time formats: the time without "()".
      const real = Intl.RelativeTimeFormat;
      (Intl as unknown as Record<string, unknown>).RelativeTimeFormat = undefined;
      try {
        kit.stamp(s1, new Date(2026, 10, 16, 14, 0, 0).toISOString());
        expect(s1.textContent).not.toContain("(");
      } finally {
        (Intl as unknown as Record<string, unknown>).RelativeTimeFormat = real;
      }
    } finally {
      vi.useRealTimers();
    }
  });
  it("formats numbers, percentages and dates by the page's language", async () => {
    await table([["a", "1"]]);
    const fmt = (w as unknown as { KitUI: { format: KitFormat } }).KitUI.format;
    document.documentElement.lang = "en";
    expect(fmt.number(1234.5)).toBe("1,234.5");
    expect(fmt.number(1234.5, { decimals: 2 })).toBe("1,234.50");
    expect(fmt.percent(41.73)).toBe("41.7%");
    expect(fmt.percent(100)).toBe("100%");
    expect(fmt.date("2026-10-09")).toBe("9 Oct 2026");
    expect(fmt.date("2026-10-09T14:00:00", { time: true })).toMatch(/9 Oct 2026, 14:00/);
    expect(fmt.number("n/a")).toBe("-");
    expect(fmt.date("")).toBe("-");
    document.documentElement.lang = "nl";
    expect(fmt.number(1234.5)).toBe("1.234,5");
    document.documentElement.lang = "";
  });
  it("adds a checkbox column for row selection, select-all, the bulk bar and kit:selection", async () => {
    document.body.innerHTML = `<div class="kit-bulk" data-kit-bulk="p" hidden><span class="kit-bulk__count"></span></div>
      <table class="kit-table" id="p" data-kit-sort data-kit-select><thead><tr><th>Item</th><th class="kit-num">N</th></tr></thead>
      <tbody><tr data-id="a"><td>A</td><td class="kit-num">1</td></tr><tr data-id="b"><td>B</td><td class="kit-num">2</td></tr><tr data-kit-empty hidden><td colspan="2">none</td></tr></tbody></table>`;
    load(kitJs);
    await tick();
    const tb = document.getElementById("p") as KitTable;
    expect(tb.tHead!.rows[0].cells[0].className).toBe("kit-table__select");
    expect(tb.tBodies[0].rows[0].cells[0].querySelector("input[type=checkbox]")).not.toBeNull();
    expect((tb.querySelector("[data-kit-empty] td") as HTMLTableCellElement).colSpan).toBe(3);
    let seen: string[] = [];
    tb.addEventListener("kit:selection", (e) => { seen = (e as CustomEvent).detail.ids; });
    const box = tb.tBodies[0].rows[1].cells[0].querySelector("input") as HTMLInputElement;
    box.checked = true;
    box.dispatchEvent(new Event("change", { bubbles: true }));
    expect(seen).toEqual(["b"]);
    expect(tb.tBodies[0].rows[1].getAttribute("aria-selected")).toBe("true");
    const bulk = document.querySelector(".kit-bulk") as HTMLElement;
    expect(bulk.hidden).toBe(false);
    expect(bulk.querySelector(".kit-bulk__count")!.textContent).toBe("1 selected");
    tb.kitSelect(true);
    expect(tb.kitSelected().length).toBe(2);
    tb.kitSelect(false);
    expect(bulk.hidden).toBe(true);
    // Sorting still works with the extra column: the numeric column is now the third cell.
    const names = () => Array.from(tb.tBodies[0].rows).filter((r) => !r.hidden && !r.hasAttribute("data-kit-empty")).map((r) => r.cells[1].textContent);
    sortBy(tb, 2);
    expect(names()).toEqual(["A", "B"]);
    sortBy(tb, 2);
    expect(names()).toEqual(["B", "A"]);
  });
  it("opens and closes the shell navigation from its menu button", async () => {
    document.body.innerHTML = `<div class="kit-shell"><header><button data-kit-shell-menu aria-controls="nav" aria-expanded="false" type="button">Menu</button></header>
      <nav class="kit-shell__nav" id="nav"><a href="#x">One</a></nav></div>`;
    load(kitJs);
    await tick();
    const btn = document.querySelector("[data-kit-shell-menu]") as HTMLButtonElement;
    const nav = document.getElementById("nav")!;
    btn.click();
    expect(nav.classList.contains("is-open")).toBe(true);
    expect(btn.getAttribute("aria-expanded")).toBe("true");
    (nav.querySelector("a") as HTMLAnchorElement).click();
    expect(nav.classList.contains("is-open")).toBe(false);
    btn.click();
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    expect(nav.classList.contains("is-open")).toBe(false);
  });
});

describe("kit-charts.js bar list shares", () => {
  it("fills a bar to its share when shares are shown, and to the largest row otherwise", () => {
    document.body.innerHTML = '<div class="kit-chart" id="a"></div><div class="kit-chart" id="b"></div>';
    load(chartsJs);
    const items = [{ label: "A", value: 30 }, { label: "B", value: 10 }, { label: "C", value: 60 }];
    w.KitCharts.barlist(document.getElementById("a")!, { items, share: true });
    w.KitCharts.barlist(document.getElementById("b")!, { items });
    const widths = (id: string) => Array.from(document.querySelectorAll<HTMLElement>(`#${id} .kit-barlist__fill`)).map((f) => f.style.width);
    expect(widths("a").map(parseFloat)).toEqual([30, 10, 60]);
    expect(widths("b").map(parseFloat)).toEqual([50, 16.7, 100]);
  });
});

describe("kit-charts.js charts written later", () => {
  it("draws a declared chart a script adds after the page loaded, and again when its data changes", async () => {
    document.body.innerHTML = '<div id="dash"></div>';
    load(chartsJs);
    await tick();
    document.getElementById("dash")!.innerHTML = `<div class="kit-chart" id="late" data-kit-chart="ring" aria-label="Tiers" data-kit-data='{"items":[{"label":"A","value":3},{"label":"B","value":1}]}'></div>`;
    await tick();
    const late = document.getElementById("late")!;
    expect(late.querySelector("svg")).not.toBeNull();
    expect(late.querySelector(".kit-chart__table")!.textContent).toContain("A");
    late.setAttribute("data-kit-data", '{"items":[{"label":"C","value":5}]}');
    await tick();
    expect(late.querySelector(".kit-chart__table")!.textContent).toContain("C");
    expect(late.querySelector(".kit-chart__table")!.textContent).not.toContain("A");
  });
});

describe("kit-charts.js data shapes", () => {
  it("reads a list of { label, value } as a ring's items and as a bar chart's labels and values (run 6)", () => {
    document.body.innerHTML = '<div class="kit-chart" id="r"></div><div class="kit-chart" id="b"></div>';
    load(chartsJs);
    const list = [{ label: "Power user", value: 912 }, { label: "Starter", value: 4100 }, { label: "Inactive", value: 237 }];
    w.KitCharts.ring(document.getElementById("r")!, list);
    w.KitCharts.bar(document.getElementById("b")!, list);
    for (const id of ["r", "b"]) {
      const el = document.getElementById(id)!;
      expect(el.querySelector("svg")).not.toBeNull();
      expect(el.querySelector(".kit-empty")).toBeNull();
      expect(el.querySelector(".kit-chart__table")!.textContent).toContain("Power user");
    }
    // name/count and labels with values
    w.KitCharts.barlist(document.getElementById("r")!, [{ name: "A", count: 3 }]);
    expect(document.querySelector("#r .kit-barlist__row")!.textContent).toContain("A");
    w.KitCharts.ring(document.getElementById("b")!, { labels: ["X", "Y"], values: [1, 2] });
    expect(document.querySelector("#b svg")).not.toBeNull();
  });
  it("reads values, a series without labels and a data list as a bar chart, and labels with a series as a ring", () => {
    document.body.innerHTML = '<div class="kit-chart" id="a"></div><div class="kit-chart" id="b"></div><div class="kit-chart" id="c"></div><div class="kit-chart" id="d"></div>';
    load(chartsJs);
    const table = (id: string) => document.querySelector(`#${id} .kit-chart__table`)!.textContent;
    w.KitCharts.bar(document.getElementById("a")!, { values: [4, 5], name: "V" });
    expect(document.querySelectorAll("#a .kit-chart__bar").length).toBe(2);
    expect(table("a")).toContain("V");
    w.KitCharts.bar(document.getElementById("b")!, { series: [{ name: "S", values: [1, 2, 3] }] });
    expect(table("b")).toMatch(/1.*2.*3/);
    w.KitCharts.bar(document.getElementById("c")!, { data: [{ name: "North", count: 2 }, { key: "South", total: 3 }] });
    expect(table("c")).toContain("North");
    expect(table("c")).toContain("South");
    w.KitCharts.ring(document.getElementById("d")!, { labels: ["X", "Y"], series: [{ values: [1, 3] }] });
    expect(table("d")).toContain("75%");
  });
  it("lists every part of a stacked bar in its tooltip, and a bar list's Show all shows the rest", () => {
    document.body.innerHTML = '<div class="kit-chart" id="s"></div><div class="kit-chart" id="l"></div>';
    load(chartsJs);
    const s = document.getElementById("s")!;
    w.KitCharts.bar(s, { labels: ["Mon"], series: [{ name: "Bikes", values: [3] }, { name: "Scooters", values: [1] }], stacked: "percent" });
    const bar = s.querySelector(".kit-chart__bar") as unknown as SVGGraphicsElement & { getBBox: () => DOMRect };
    bar.getBBox = () => ({ x: 0, y: 0, width: 10, height: 10 }) as DOMRect;
    bar.dispatchEvent(new Event("mouseenter"));
    expect(s.querySelector(".kit-chart__tip")!.textContent).toBe("Mon · 4Bikes: 3 (75%)Scooters: 1 (25%)");
    const l = document.getElementById("l")!;
    w.KitCharts.barlist(l, { items: [{ label: "A", value: 3 }, { label: "B", value: 2 }, { label: "C", value: 1 }], limit: 2 });
    expect(l.querySelectorAll(".kit-barlist__row").length).toBe(2);
    (l.querySelector(".kit-barlist__more") as HTMLButtonElement).click();
    expect(l.querySelectorAll(".kit-barlist__row").length).toBe(3);
    expect(l.querySelector(".kit-barlist__more")!.textContent).toBe("Show the top 2");
  });
  it("says which shape it expected when the data cannot be read, and keeps the empty state for no data", () => {
    document.body.innerHTML = '<div class="kit-chart" id="x"></div><div class="kit-chart" id="n"></div>';
    load(chartsJs);
    const x = document.getElementById("x")!, n = document.getElementById("n")!;
    w.KitCharts.bar(x, { rows: [1, 2, 3] });
    expect(x.hasAttribute("data-kit-shape-error")).toBe(true);
    expect(x.textContent).toContain("Expected:");
    w.KitCharts.ring(n, { items: [] });
    expect(n.hasAttribute("data-kit-shape-error")).toBe(false);
    expect(n.querySelector(".kit-empty")!.textContent).toBe("Nothing to show");
  });
});

describe("kit-charts.js scatter", () => {
  it("draws points with axes, skips what is not a point, and has an empty state", () => {
    document.body.innerHTML = '<div class="kit-chart" id="s"></div><div class="kit-chart" id="e"></div>';
    load(chartsJs);
    const s = document.getElementById("s")!, e = document.getElementById("e")!;
    w.KitCharts.scatter(s, { xLabel: "Temp", yLabel: "Rentals", series: [{ name: "A", points: [{ x: 4, y: 210, label: "3 Mar" }, { x: "n/a", y: 1 }, { x: 24, y: 740 }] }, { name: "B", points: [{ x: 6, y: 380, r: 8 }] }], selectable: true });
    expect(s.querySelectorAll(".kit-chart__point").length).toBe(3);
    expect(s.querySelector("svg")!.getAttribute("role")).toBe("group");
    expect(Array.from(s.querySelectorAll(".kit-chart__label")).some((l) => l.textContent === "Temp")).toBe(true);
    expect(s.querySelector(".kit-chart__table")!.textContent).toContain("3 Mar");
    w.KitCharts.scatter(e, { series: [{ name: "A", points: [] }] });
    expect(e.querySelector(".kit-empty")).not.toBeNull();
  });
});

describe("kit.js filling from data", () => {
  type Fill = Window & { KitUI: { fillTable: (t: string, rows: unknown[], c?: unknown) => number; options: (s: string, v: unknown[], o?: unknown) => HTMLSelectElement } };
  it("writes a table from its header cells, keeps the empty row and sorts numbers by value", async () => {
    document.body.innerHTML = `<table class="kit-table" id="t" data-kit-sort><thead><tr><th data-key="Name">Name</th><th data-key="Count" class="kit-num">Count</th><th data-key="Seen" data-format="date">Seen</th></tr></thead>
      <tbody><tr data-kit-empty hidden><td colspan="3"><div class="kit-empty"><p class="kit-empty__title">None</p></div></td></tr></tbody></table>`;
    load(kitJs);
    await tick();
    const ui = (window as unknown as Fill).KitUI;
    expect(ui.fillTable("#t", [{ Name: "B", Count: 1234, Seen: "2026-10-09" }, { Name: "A", Count: null, Seen: null }])).toBe(2);
    const rows = Array.from(document.querySelectorAll<HTMLTableRowElement>("#t tbody tr:not([data-kit-empty])"));
    expect(rows.map((r) => r.cells[0].textContent)).toEqual(["B", "A"]);
    expect(rows[0].cells[1].className).toBe("kit-num");
    expect(rows[0].cells[1].getAttribute("data-sort")).toBe("1234");
    expect(rows[1].cells[1].textContent).toBe("-");
    expect(rows[0].cells[2].textContent).toMatch(/2026/);
    expect((document.querySelector("#t tr[data-kit-empty]") as HTMLElement).hidden).toBe(true);
    ui.fillTable("#t", []);
    expect(document.querySelectorAll("#t tbody tr:not([data-kit-empty])").length).toBe(0);
    expect((document.querySelector("#t tr[data-kit-empty]") as HTMLElement).hidden).toBe(false);
  });
  it("fills a select and keeps the choice while it is still there", async () => {
    document.body.innerHTML = '<select id="s"><option value="b" selected>b</option></select>';
    load(kitJs);
    await tick();
    const ui = (window as unknown as Fill).KitUI;
    const sel = ui.options("#s", ["a", "b", { value: "c", label: "See" }], { all: "All" });
    expect(Array.from(sel.options).map((o) => o.textContent)).toEqual(["All", "a", "b", "See"]);
    expect(sel.value).toBe("b");
    ui.options("#s", ["a"], { all: "All" });
    expect(sel.value).toBe("");
  });
});

describe("kit.js tab panels (revision 13)", () => {
  it("shows the selected tab's panel, hides the rest, and reports the switch", async () => {
    document.body.innerHTML = `<div class="kit-tabs" role="tablist"><button class="kit-tab" role="tab" aria-selected="false" aria-controls="p1" type="button">One</button><button class="kit-tab" role="tab" aria-selected="true" aria-controls="p2" type="button">Two</button></div>
      <div id="p1">first</div><div id="p2">second</div>`;
    load(kitJs);
    await tick();
    const p1 = document.getElementById("p1")!, p2 = document.getElementById("p2")!;
    expect([p1.hidden, p2.hidden]).toEqual([true, false]);
    expect(p2.getAttribute("role")).toBe("tabpanel");
    const tabs = Array.from(document.querySelectorAll<HTMLButtonElement>(".kit-tab"));
    expect(p2.getAttribute("aria-labelledby")).toBe(tabs[1].id);
    const seen: string[] = [];
    document.addEventListener("kit:tab", (e) => seen.push((e as CustomEvent).detail.value));
    tabs[0].click();
    expect([p1.hidden, p2.hidden]).toEqual([false, true]);
    expect(tabs.map((b) => b.getAttribute("aria-selected"))).toEqual(["true", "false"]);
    expect(seen).toEqual(["p1"]);
  });
  it("leaves tabs without panels to the page", async () => {
    document.body.innerHTML = `<div class="kit-tabs" role="tablist"><button class="kit-tab" role="tab" aria-selected="true" type="button">A</button><button class="kit-tab" role="tab" aria-selected="false" type="button">B</button></div><div id="x">x</div>`;
    load(kitJs);
    await tick();
    (document.querySelectorAll<HTMLButtonElement>(".kit-tab")[1]).click();
    expect(document.getElementById("x")!.hidden).toBe(false);
    expect(document.querySelectorAll(".kit-tab")[1].getAttribute("aria-selected")).toBe("false");
  });
});

describe("kit.js basics (revision 11)", () => {
  type Basics = Window & { KitUI: { confirm: (t: string, o?: Record<string, unknown>) => Promise<boolean>; alert: (t: string, o?: Record<string, unknown>) => Promise<void> } };
  const b = window as unknown as Basics;
  it("gives a tree its toggles and roles, moves with the arrow keys, opens and closes, and picks with Enter", async () => {
    document.body.innerHTML = `<ul class="kit-tree" data-kit-tree aria-label="Folders" id="tree">
      <li data-value="a" aria-expanded="true"><div class="kit-tree__row">A</div><ul><li data-value="a1"><div class="kit-tree__row">A1</div></li></ul></li>
      <li data-value="b" aria-expanded="false"><div class="kit-tree__row">B</div><ul><li data-value="b1"><div class="kit-tree__row">B1</div></li></ul></li>
      <li data-value="c"><div class="kit-tree__row">C</div></li></ul>`;
    load(kitJs);
    await tick();
    const tree = document.getElementById("tree")!;
    expect(tree.getAttribute("role")).toBe("tree");
    expect(tree.querySelectorAll("li[role=treeitem]").length).toBe(5);
    expect(tree.querySelectorAll("ul[role=group]").length).toBe(2);
    expect(tree.querySelectorAll(".kit-tree__toggle").length).toBe(2);
    expect(tree.querySelectorAll(".kit-tree__spacer").length).toBe(3);
    const rows = () => Array.from(tree.querySelectorAll<HTMLElement>(".kit-tree__row"));
    expect(rows().filter((r) => r.tabIndex === 0).length).toBe(1);
    const first = rows()[0];
    first.focus();
    first.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    expect(document.activeElement!.textContent).toBe("A1");
    document.activeElement!.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    expect(document.activeElement!.textContent!.trim()).toBe("B");   // B1 is inside a closed branch
    document.activeElement!.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
    expect(tree.querySelector("li[data-value=b]")!.getAttribute("aria-expanded")).toBe("true");
    document.activeElement!.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }));
    expect(tree.querySelector("li[data-value=b]")!.getAttribute("aria-expanded")).toBe("false");
    const picked: string[] = [];
    tree.addEventListener("kit:select", (e) => picked.push((e as CustomEvent).detail.value));
    document.activeElement!.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    expect(picked).toEqual(["b"]);
    expect(tree.querySelector("li[data-value=b]")!.getAttribute("aria-selected")).toBe("true");
    (tree.querySelector("li[data-value=c] .kit-tree__row") as HTMLElement).click();
    expect(picked).toEqual(["b", "c"]);
    expect(tree.querySelectorAll("li[aria-selected=true]").length).toBe(1);
  });
  it("opens a popover from its button, closes it with Escape or a click beside it, and gives focus back", async () => {
    document.body.innerHTML = `<div class="kit-popover-wrap"><button class="kit-btn" id="pb" data-kit-popover="pop" aria-expanded="false">Columns</button>
      <div class="kit-popover" id="pop" hidden><label class="kit-check"><input type="checkbox" id="pc"> Station</label></div></div><p id="out">outside</p>`;
    load(kitJs);
    await tick();
    const btn = document.getElementById("pb")!, pop = document.getElementById("pop")!;
    const events: string[] = [];
    pop.addEventListener("kit:open", () => events.push("open"));
    pop.addEventListener("kit:close", () => events.push("close"));
    btn.click();
    expect(pop.hidden).toBe(false);
    expect(btn.getAttribute("aria-expanded")).toBe("true");
    expect(btn.getAttribute("aria-controls")).toBe("pop");
    expect(document.activeElement!.id).toBe("pc");
    document.activeElement!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    expect(pop.hidden).toBe(true);
    expect(document.activeElement).toBe(btn);
    btn.click();
    document.getElementById("out")!.click();
    expect(pop.hidden).toBe(true);
    expect(events).toEqual(["open", "close", "open", "close"]);
  });
  it("shows confirm and alert as kit dialogs and answers with a promise", async () => {
    document.body.innerHTML = "<p>page</p>";
    load(kitJs);
    await tick();
    const p = b.KitUI.confirm("Delete 3 items?", { title: "Delete", ok: "Delete", danger: true });
    const d = document.querySelector("dialog.kit-dialog")!;
    expect(d).not.toBeNull();
    expect(d.getAttribute("role")).toBe("alertdialog");
    expect(d.querySelector("h3.kit-h3")!.textContent).toBe("Delete");
    const buttons = Array.from(d.querySelectorAll<HTMLButtonElement>(".kit-dialog__actions .kit-btn"));
    expect(buttons.map((x) => x.textContent)).toEqual(["Cancel", "Delete"]);
    expect(buttons[1].classList.contains("kit-btn--danger")).toBe(true);
    buttons[1].click();
    expect(await p).toBe(true);
    expect(document.querySelector("dialog.kit-dialog")).toBeNull();   // gone once answered
    const q = b.KitUI.confirm("Sure?");
    (document.querySelector("dialog.kit-dialog .kit-btn") as HTMLButtonElement).click();   // Cancel
    expect(await q).toBe(false);
    const a = b.KitUI.alert("Saved.");
    const ad = document.querySelector("dialog.kit-dialog")!;
    expect(ad.querySelectorAll(".kit-btn").length).toBe(1);
    (ad.querySelector(".kit-btn") as HTMLButtonElement).click();
    expect(await a).toBeUndefined();
    expect(document.querySelector("dialog.kit-dialog")).toBeNull();
  });
  it("shows one box at a time with Cancel focused for danger, and keeps an Escape that closed a popover from closing more", async () => {
    document.body.innerHTML = '<div class="kit-popover-wrap"><button type="button" data-kit-popover="pp" aria-expanded="false">P</button><div class="kit-popover" id="pp" hidden><input id="pi"></div></div>';
    load(kitJs);
    await tick();
    const first = b.KitUI.confirm("Delete?", { danger: true });
    const second = b.KitUI.confirm("And this?");
    expect(document.querySelectorAll("dialog.kit-dialog").length).toBe(1);   // the second waits
    expect((document.activeElement as HTMLElement).getAttribute("data-value")).toBe("cancel");
    (document.querySelector('dialog.kit-dialog [data-value="ok"]') as HTMLButtonElement).click();
    expect(await first).toBe(true);
    expect(document.querySelector("dialog.kit-dialog p")!.textContent).toBe("And this?");
    (document.querySelector('dialog.kit-dialog [data-value="cancel"]') as HTMLButtonElement).click();
    expect(await second).toBe(false);
    (document.querySelector("[data-kit-popover]") as HTMLButtonElement).click();
    expect(document.getElementById("pp")!.hidden).toBe(false);
    const esc = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    document.getElementById("pi")!.dispatchEvent(esc);
    expect(document.getElementById("pp")!.hidden).toBe(true);
    expect(esc.defaultPrevented).toBe(true);   // a dialog or side panel around the popover stays open
  });
  it("puts an error toast in the alert region, made empty at start, and says its tone, not only its colour", () => {
    const s = w.KitUI.toast("Saved") as unknown as HTMLElement;
    expect(s.parentElement!.className).toBe("kit-toasts");   // the polite status region
    expect(s.getAttribute("role")).toBeNull();
    const alerts = document.querySelector(".kit-toasts > .kit-toasts__alerts")!;
    expect(alerts.getAttribute("role")).toBe("alert");   // made with the stack, empty, before the first error
    expect(alerts.childElementCount).toBe(0);
    const t = (w.KitUI.toast as unknown as (text: string, o: Record<string, unknown>) => HTMLElement)("Upload failed", { tone: "error" });
    expect(t.parentElement).toBe(alerts);
    expect(t.getAttribute("role")).toBeNull();   // the region speaks, not the toast as well
    expect(t.textContent).toBe("Error: Upload failed\u00d7");   // the tone word, the text, and the Dismiss button's mark (no kit-icons.js here)
  });
  it("gives a toast one action that runs and closes it, and keeps it at least 10 s", () => {
    vi.useFakeTimers();
    try {
      const toast = (w.KitUI.toast as unknown as (text: string, o?: Record<string, unknown>) => HTMLElement);
      let undone = 0;
      const t = toast("Row deleted", { action: { label: "Undo", onClick: () => { undone++; } } });
      const a = t.querySelector<HTMLButtonElement>(".kit-toast__action")!;
      expect(a.textContent).toBe("Undo");
      expect(a.className).toBe("kit-btn kit-btn--ghost kit-btn--sm kit-toast__action");
      expect(a.nextElementSibling!.classList.contains("kit-toast__close")).toBe(true);   // Dismiss stays last
      vi.advanceTimersByTime(9000);
      expect(t.classList.contains("is-leaving")).toBe(false);
      a.click();
      expect(undone).toBe(1);
      expect(t.classList.contains("is-leaving")).toBe(true);
      const u = toast("Sent", { action: { label: "Open" }, ms: 3000 });
      vi.advanceTimersByTime(9900);
      expect(u.classList.contains("is-leaving")).toBe(false);
      vi.advanceTimersByTime(200);
      expect(u.classList.contains("is-leaving")).toBe(true);
      expect(toast("Saved", { action: {} }).querySelector(".kit-toast__action")).toBeNull();   // no label, no button
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("kit.css pointer rules", () => {
  // Read from disk: vitest hands an imported stylesheet over empty, ?raw included.
  const css = fs.readFileSync(path.resolve(import.meta.dirname, "../../../templates/ui-kit/kit.css"), "utf8");
  it("shows hover looks only to a fine pointer", () => {
    const hovers = css.match(/@media[^{]*hover:\s*hover[^{]*\{/g) || [];
    expect(hovers.length).toBeGreaterThan(0);
    expect(hovers.filter((m) => !/pointer:\s*fine/.test(m))).toEqual([]);
  });
  it("gives small controls a 44px reach on touch screens through an invisible ::after", () => {
    const coarse = css.slice(css.indexOf("@media (pointer: coarse)"));
    expect(coarse.length).toBeLessThan(css.length);
    for (const part of [".kit-btn:not([aria-busy=\"true\"])", ".kit-segmented button", ".kit-tab", ".kit-calendar__day", ".kit-tip"]) expect(coarse).toContain(part);
    expect(coarse).toMatch(/width: max\(100%, 44px\); height: max\(100%, 44px\)/);
    expect(coarse).toMatch(/font-size: max\(16px, 1em\)/);
  });
  // The shared typography and motion details (19 Nov 2026).
  it("puts link underlines 0.2em below the text and keeps sup and sub out of the line height", () => {
    expect(css).toMatch(/\.kit-link \{[^}]*text-underline-offset: 0\.2em/);
    expect(css).toMatch(/\.kit-page sup, \.kit-page sub \{[^}]*line-height: 0/);
  });
  it("balances headings, keeps prose from a lone last word and stops panel titles at two lines", () => {
    expect(css).toMatch(/\.kit-h1, \.kit-h2, \.kit-h3[^{]*\{ text-wrap: balance; \}/);
    expect(css).toMatch(/\.kit-prose p \{ text-wrap: pretty; \}/);
    expect(css).toMatch(/\.kit-panel__title \{[^}]*line-clamp: 2/);
  });
  it("moves indicators and the switch knob with ease-in-out, a token every theme sheet defines", () => {
    for (const sel of [".kit-tabs__indicator", ".kit-segmented__indicator", ".kit-switch__track::after"]) {
      const at = css.indexOf(sel + " {");
      expect(at).toBeGreaterThan(-1);
      expect(css.slice(at, css.indexOf("}", at))).toContain("var(--kit-ease-in-out");
    }
    for (const sheet of ["tokens.css", "tokens-neutral.css"]) {
      expect(fs.readFileSync(path.resolve(import.meta.dirname, "../../../templates/ui-kit", sheet), "utf8")).toMatch(/--kit-ease-in-out: cubic-bezier\(/);
    }
  });
});

describe("kit.js drop zone file names", () => {
  async function drop(names: string[]) {
    document.body.innerHTML = `<label class="kit-drop" data-kit-drop><input type="file" multiple><ul class="kit-drop__files"></ul></label>`;
    load(kitJs);
    await tick();
    const zone = document.querySelector(".kit-drop") as HTMLElement;
    const files = names.map((n) => new File(["x"], n));
    const ev = new Event("drop", { bubbles: true, cancelable: true }) as Event & { dataTransfer: unknown };
    ev.dataTransfer = { files };
    zone.dispatchEvent(ev);
    return Array.from(document.querySelectorAll(".kit-drop__file"));
  }
  it("splits a name into a stem that shrinks and an extension that stays, with the full name as title", async () => {
    const [row] = await drop(["quarterly-report-final.xlsx"]);
    expect(row.getAttribute("title")).toBe("quarterly-report-final.xlsx");
    expect(row.querySelector(".kit-drop__stem")!.textContent).toBe("quarterly-report-final");
    expect(row.querySelector(".kit-drop__ext")!.textContent).toBe(".xlsx");
  });
  it("keeps a dot file or a name without a dot whole, and never turns a name into markup", async () => {
    const rows = await drop([".env", "README", "<b>x</b>.txt"]);
    expect(rows.map((r) => r.querySelector(".kit-drop__ext")?.textContent ?? null)).toEqual([null, null, ".txt"]);
    expect(rows[0].textContent).toBe(".env");
    expect(rows[2].querySelector("b")).toBeNull();
    expect(rows[2].querySelector(".kit-drop__stem")!.textContent).toBe("<b>x</b>");
  });
});

describe("kit.js element specs: fallbacks, names and keys", () => {
  const press = (el: Element, key: string, opts: KeyboardEventInit = {}) => {
    const e = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...opts });
    el.dispatchEvent(e);
    return e.defaultPrevented;
  };
  it("takes only the dropped files its accept list allows, says which it left, and keeps the highlight over its children", async () => {
    document.body.innerHTML = `<label class="kit-drop" data-kit-drop><input type="file" accept=".csv"><span class="kit-drop__title">Drop</span><ul class="kit-drop__files"></ul></label>`;
    load(kitJs);
    await tick();
    const zone = document.querySelector(".kit-drop") as HTMLElement;
    let got: string[] = [];
    zone.addEventListener("kit:files", (e) => { got = Array.from((e as CustomEvent).detail.files as File[]).map((f) => f.name); });
    zone.dispatchEvent(new Event("dragenter", { bubbles: true, cancelable: true }));
    zone.querySelector(".kit-drop__title")!.dispatchEvent(new Event("dragenter", { bubbles: true, cancelable: true }));
    zone.dispatchEvent(new Event("dragleave", { bubbles: true }));
    expect(zone.classList.contains("is-over")).toBe(true);
    const ev = new Event("drop", { bubbles: true, cancelable: true }) as Event & { dataTransfer: unknown };
    ev.dataTransfer = { files: [new File(["a"], "a.csv", { type: "text/csv" }), new File(["b"], "b.png", { type: "image/png" }), new File(["c"], "c.csv")] };
    zone.dispatchEvent(ev);
    expect(zone.classList.contains("is-over")).toBe(false);
    expect(got).toEqual(["a.csv"]); // not multiple: the first accepted file only
    expect(zone.querySelector("[role=alert]")!.textContent).toContain("b.png");
  });
  it("falls back to the initials when an avatar's photo fails, and leaves an avatar beside its name unnamed", async () => {
    document.body.innerHTML = '<span data-kit-avatar="Ada Lovelace"><img alt="" src="broken.png"></span><span data-kit-avatar="Grace Hopper" aria-hidden="true"></span>';
    load(kitJs);
    await tick();
    const [a, b] = Array.from(document.querySelectorAll("[data-kit-avatar]")) as HTMLElement[];
    a.querySelector("img")!.dispatchEvent(new Event("error"));
    expect(a.textContent).toBe("AL");
    expect(b.hasAttribute("role")).toBe(false);
    expect(b.hasAttribute("aria-label")).toBe(false);
  });
  it("opens a menu from its button with ArrowUp on the last item, and the rows are not Tab stops", async () => {
    document.body.innerHTML = '<div class="kit-menu"><button data-kit-menu aria-expanded="false" type="button">Actions</button><div class="kit-menu__list" hidden><button class="kit-menu__item" type="button">Edit</button><button class="kit-menu__item" type="button">Delete</button></div></div>';
    load(kitJs);
    await tick();
    const btn = document.querySelector("[data-kit-menu]") as HTMLButtonElement;
    expect(press(btn, "ArrowUp")).toBe(true);
    expect(btn.getAttribute("aria-expanded")).toBe("true");
    expect(document.activeElement!.textContent).toBe("Delete");
    expect(Array.from(document.querySelectorAll(".kit-menu__item")).map((i) => i.getAttribute("tabindex"))).toEqual(["-1", "-1"]);
    press(document.activeElement!, "Escape");
    expect(press(btn, "ArrowDown")).toBe(true);
    expect(document.activeElement!.textContent).toBe("Edit");
  });
  it("makes a popover a non-modal dialog named by its button and leaves an input-method Escape alone", async () => {
    document.body.innerHTML = '<div class="kit-popover-wrap"><button type="button" data-kit-popover="pq" aria-expanded="false">Columns</button><div class="kit-popover" id="pq" hidden><input aria-label="Name"></div></div>';
    load(kitJs);
    await tick();
    (document.querySelector("[data-kit-popover]") as HTMLButtonElement).click();
    const panel = document.getElementById("pq")!;
    expect(panel.getAttribute("role")).toBe("dialog");
    expect(document.getElementById(panel.getAttribute("aria-labelledby")!)!.textContent).toBe("Columns");
    press(document.activeElement!, "Escape", { isComposing: true });
    expect(panel.hidden).toBe(false);
    press(document.activeElement!, "Escape");
    expect(panel.hidden).toBe(true);
  });
  it("clears a search box with a second Escape once its list is closed", async () => {
    document.body.innerHTML = '<div class="kit-search" data-kit-search><input class="kit-input" aria-label="Find"><ul class="kit-search__list"><li class="kit-search__item">One</li></ul></div>';
    load(kitJs);
    await tick();
    const input = document.querySelector(".kit-search input") as HTMLInputElement;
    input.value = "On";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    press(input, "Escape");
    expect(input.getAttribute("aria-expanded")).toBe("false");
    expect(input.value).toBe("On");
    expect(press(input, "Escape")).toBe(true);
    expect(input.value).toBe("");
  });
  it("names each board column and its list by the column's title", async () => {
    document.body.innerHTML = '<div class="kit-board"><section class="kit-board__column"><h3 class="kit-board__title">To do</h3><ul class="kit-board__list" data-kit-board="todo"><li data-id="1">One</li></ul></section></div>';
    load(kitJs);
    await tick();
    const col = document.querySelector(".kit-board__column")!;
    const id = col.getAttribute("aria-labelledby")!;
    expect(document.getElementById(id)!.textContent).toBe("To do");
    expect(document.querySelector(".kit-board__list")!.getAttribute("aria-labelledby")).toBe(id);
  });
});

describe("page check: kit classes without a rule", () => {
  const pageCheck = pageCheckJs;
  it("lists kit classes on the page, also ones a script added, that no loaded stylesheet has a rule for", async () => {
    document.head.innerHTML = "<style>.kit-panel { padding: 4px; } @media (min-width: 1px) { .kit-table th { color: red; } }</style>";
    document.body.innerHTML = '<div class="kit-panel"><table class="kit-table"><thead><tr><th><button class="kit-table__sort">Name</button></th></tr></thead></table><span class="kit-chart__swatch other"></span></div><template><i class="kit-ghost"></i></template>';
    const out = JSON.parse(await (new Function("return (\n" + pageCheck + "\n)")() as Promise<string>)) as { kind: string; classes?: string[] }[];
    const kit = out.find((f) => f.kind === "kitcss");
    expect(kit).toBeDefined();
    expect(kit!.classes).toEqual(["kit-chart__swatch", "kit-table__sort"]);   // kit-panel and kit-table have rules; a template is not shown
    document.head.innerHTML = "<style>.kit-panel, .kit-table, .kit-table__sort, .kit-chart__swatch { margin: 0; }</style>";
    const out2 = JSON.parse(await (new Function("return (\n" + pageCheck + "\n)")() as Promise<string>)) as { kind: string }[];
    expect(out2.some((f) => f.kind === "kitcss")).toBe(false);
  });
  it("reports numbers of four or more digits without thousands separators, not years, codes or grouped numbers (run 7)", async () => {
    document.head.innerHTML = "";
    // jsdom has no layout: every element gets one box, so the check sees it as shown.
    const rects = Element.prototype.getClientRects;
    Element.prototype.getClientRects = function () { return [{}] as unknown as DOMRectList; };
    document.body.innerHTML = '<div class="kit-figure__value">8377</div><div class="kit-figure__value">1,035,344</div><table><caption>Power users</caption><tbody><tr><td>Shunta Takao</td><td>2195</td><td>2026</td><td>00123</td><td>16</td></tr></tbody></table>';
    const out = JSON.parse(await (new Function("return (\n" + pageCheck + "\n)")() as Promise<string>)) as { kind: string; text: string }[];
    const num = out.find((f) => f.kind === "number");
    expect(num).toBeDefined();
    expect(num!.text).toMatch(/^shows 2 numbers of four or more digits without thousands separators \(such as '8377'/);
    document.body.innerHTML = '<div class="kit-figure__value">8,377</div><table><tbody><tr><td>2,195</td><td>2026</td></tr></tbody></table>';
    const out2 = JSON.parse(await (new Function("return (\n" + pageCheck + "\n)")() as Promise<string>)) as { kind: string }[];
    expect(out2.some((f) => f.kind === "number")).toBe(false);
    Element.prototype.getClientRects = rects;
  });
});

describe("kit.js menus, boards, calendars, pagers and filled cells", () => {
  type Parts = Window & { KitUI: { calendar: (el: HTMLElement, o: unknown) => void; fillTable: (t: string, rows: unknown[], c?: unknown, o?: unknown) => number } };
  const ui = () => (w as unknown as Parts).KitUI;
  const press = (el: Element, key: string, more: KeyboardEventInit = {}) => el.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...more }));
  it("moves through a menu with the arrow keys (wrapping round), Home and End, and closes it with Escape", async () => {
    document.body.innerHTML = '<div class="kit-menu"><button data-kit-menu aria-expanded="false" type="button">Actions</button><div class="kit-menu__list" hidden>' +
      '<button class="kit-menu__item" type="button">Edit</button><button class="kit-menu__item" type="button" disabled>Off</button><button class="kit-menu__item" type="button" data-value="del">Delete</button></div></div>';
    load(kitJs);
    await tick();
    const btn = document.querySelector("[data-kit-menu]") as HTMLButtonElement;
    const items = Array.from(document.querySelectorAll(".kit-menu__item")) as HTMLButtonElement[];
    btn.click();
    expect(document.activeElement).toBe(items[0]);
    press(items[0], "ArrowUp");
    expect(document.activeElement).toBe(items[2]);   // round to the last item; a disabled one is skipped
    press(items[2], "ArrowDown");
    expect(document.activeElement).toBe(items[0]);
    press(items[0], "End");
    expect(document.activeElement).toBe(items[2]);
    press(items[2], "Escape");
    expect(btn.getAttribute("aria-expanded")).toBe("false");
    expect(document.activeElement).toBe(btn);
    let picked = "";
    document.querySelector(".kit-menu")!.addEventListener("kit:menu", (e) => { picked = (e as CustomEvent).detail.value; });
    btn.click();
    items[2].click();
    expect(picked).toBe("del");
  });
  it("moves a board card with Alt and the arrow keys, and only then", async () => {
    document.body.innerHTML = '<div class="kit-board"><ul data-kit-board="todo"><li data-id="1">One</li><li data-id="2">Two</li></ul><ul data-kit-board="done"></ul></div>';
    load(kitJs);
    await tick();
    const moves: string[] = [];
    document.addEventListener("kit:move", (e) => { const d = (e as CustomEvent).detail; moves.push(d.id + ":" + d.from + ">" + d.to + "@" + d.index); });
    const one = document.querySelector('[data-id="1"]') as HTMLElement;
    press(one, "ArrowUp", { altKey: true });     // already at the top: nothing
    press(one, "ArrowRight");                    // no Alt: nothing
    press(one, "ArrowDown", { altKey: true });
    press(one, "ArrowRight", { altKey: true });
    press(one, "ArrowRight", { altKey: true });  // no list further right: nothing
    expect(moves).toEqual(["1:todo>todo@1", "1:todo>done@0"]);
    expect(one.parentElement!.getAttribute("data-kit-board")).toBe("done");
  });
  it("draws a calendar day with three events, +N for the rest, and its count in its name", async () => {
    document.body.innerHTML = '<div data-kit-calendar data-month="2026-02"></div>';
    load(kitJs);
    await tick();
    const cal = document.querySelector("[data-kit-calendar]") as HTMLElement;
    const events = [1, 2, 3, 4, 5].map((n) => ({ date: "2026-02-10", title: "E" + n, tone: n === 1 ? "ok" : n === 2 ? "loud" : undefined }));
    ui().calendar(cal, { month: "2026-02", events });
    const day = cal.querySelector('[data-date="2026-02-10"]') as HTMLElement;
    expect(Array.from(day.querySelectorAll(".kit-calendar__event")).map((e) => e.className + "|" + e.textContent)).toEqual([
      "kit-calendar__event kit-calendar__event--ok|E1", "kit-calendar__event|E2", "kit-calendar__event|E3", "kit-calendar__event|+2"]);
    expect(day.getAttribute("aria-label")).toMatch(/, 5 items$/);
    expect(cal.querySelectorAll(".kit-calendar__dow").length).toBe(7);
    let month = "";
    cal.addEventListener("kit:month", (e) => { month = (e as CustomEvent).detail.month; });
    (cal.querySelector('[data-step="1"]') as HTMLButtonElement).click();
    expect(month).toBe("2026-03");
    ui().calendar(cal, { month: "2026-02" });
    let picked = "";
    cal.addEventListener("kit:day", (e) => { const d = (e as CustomEvent).detail; picked = d.date + ":" + d.events.length; });
    (cal.querySelector('[data-date="2026-02-10"]') as HTMLElement).click();
    expect(picked).toBe("2026-02-10:5");
  });
  it("keeps a calendar's days as one tab stop and moves with the arrow, Home, End and Page keys", async () => {
    document.body.innerHTML = '<div data-kit-calendar data-month="2024-03" data-week-start="1"></div>';
    load(kitJs);
    await tick();
    const cal = document.querySelector("[data-kit-calendar]") as HTMLElement;
    const stops = () => Array.from(cal.querySelectorAll(".kit-calendar__day")).filter((d) => (d as HTMLElement).tabIndex === 0).map((d) => d.getAttribute("data-date"));
    const at = () => document.activeElement?.getAttribute("data-date");
    const day = (iso: string) => cal.querySelector('[data-date="' + iso + '"]') as HTMLElement;
    const months: string[] = [];
    cal.addEventListener("kit:month", (e) => months.push((e as CustomEvent).detail.month));
    expect(cal.querySelector(".kit-calendar__day")!.getAttribute("data-date")).toBe("2024-02-26"); // weeks from Monday
    expect(stops()).toEqual(["2024-03-01"]); // not this month: the 1st takes the Tab key
    day("2024-03-31").focus();
    expect(stops()).toEqual(["2024-03-31"]);
    press(day("2024-03-31"), "ArrowLeft");
    expect(at()).toBe("2024-03-30");
    press(day("2024-03-30"), "ArrowUp");
    expect(at()).toBe("2024-03-23");
    press(day("2024-03-23"), "Home");
    expect(at()).toBe("2024-03-18");
    press(day("2024-03-18"), "End");
    expect(at()).toBe("2024-03-24");
    expect(months).toEqual([]); // all on the month shown
    day("2024-03-31").focus();
    press(day("2024-03-31"), "PageDown"); // 31 March -> 30 April
    expect([at(), months.join()]).toEqual(["2024-04-30", "2024-04"]);
    press(day("2024-04-30"), "PageUp", { shiftKey: true });
    expect([at(), months.join()]).toEqual(["2023-04-30", "2024-04,2023-04"]);
    press(day("2023-04-30"), "ArrowDown"); // past the days on show: the next month is drawn
    expect([at(), stops().join()]).toEqual(["2023-05-07", "2023-05-07"]);
    // Previous, Next and Today keep the focus although the month is drawn again.
    (cal.querySelector('[data-step="1"]') as HTMLButtonElement).focus();
    (cal.querySelector('[data-step="1"]') as HTMLButtonElement).click();
    expect(document.activeElement).toBe(cal.querySelector('[data-step="1"]'));
    (cal.querySelector("[data-today]") as HTMLButtonElement).click();
    const now = new Date(), iso = now.getFullYear() + "-" + ("0" + (now.getMonth() + 1)).slice(-2) + "-" + ("0" + now.getDate()).slice(-2);
    expect(months[months.length - 1]).toBe(iso.slice(0, 7));
    expect(stops()).toEqual([iso]);
    expect(day(iso).getAttribute("aria-current")).toBe("date");
    expect(document.activeElement).toBe(cal.querySelector("[data-today]"));
  });
  it("starts a calendar's week on the element's own day, else the kit's setting", async () => {
    document.documentElement.style.setProperty("--kit-week-start", "0");
    document.body.innerHTML = '<div id="a" data-kit-calendar data-month="2024-02"></div><div id="b" data-kit-calendar data-month="2024-02" data-week-start="6"></div>';
    load(kitJs);
    await tick();
    const first = (id: string) => document.querySelector("#" + id + " .kit-calendar__day")!.getAttribute("data-date");
    expect([first("a"), first("b")]).toEqual(["2024-01-28", "2024-01-27"]); // Sunday from the setting, Saturday asked for
    document.documentElement.style.removeProperty("--kit-week-start");
  });
  it("keeps the two thumbs of a range slider from crossing and reads the unit out", async () => {
    document.body.innerHTML = '<div><div class="kit-slider-range" data-kit-slider-range data-min="0" data-max="100" data-from="80" data-to="20" data-unit="km" aria-label="distance"></div></div>';
    load(kitJs);
    await tick();
    const el = document.querySelector("[data-kit-slider-range]") as HTMLElement;
    const [lo, hi] = Array.from(el.querySelectorAll("input")) as HTMLInputElement[];
    expect([lo.value, hi.value]).toEqual(["20", "80"]); // given the wrong way round: swapped
    expect([lo.getAttribute("aria-valuetext"), hi.getAttribute("aria-valuetext")]).toEqual(["20 km", "80 km"]);
    let sent = "";
    el.addEventListener("kit:slide", (e) => { const d = (e as CustomEvent).detail; sent = d.from + "-" + d.to; });
    lo.value = "95";
    lo.dispatchEvent(new Event("input", { bubbles: true }));
    expect([lo.value, sent, lo.getAttribute("aria-valuetext")]).toEqual(["80", "80-80", "80 km"]);
    hi.value = "5";
    hi.dispatchEvent(new Event("input", { bubbles: true }));
    expect([hi.value, sent]).toEqual(["80", "80-80"]);
    expect(el.nextElementSibling!.textContent).toBe("80 - 80 km");
  });
  it("writes an avatar's initials and gives the same name the same colour", async () => {
    document.body.innerHTML = '<span data-kit-avatar="ada  de lovelace"></span><span data-kit-avatar="Grace"></span><span data-kit-avatar="ada  de lovelace"><img alt=""></span>';
    load(kitJs);
    await tick();
    const [a, b, c] = Array.from(document.querySelectorAll("[data-kit-avatar]")) as HTMLElement[];
    expect([a.textContent, b.textContent]).toEqual(["AL", "G"]);
    expect(c.querySelector("img")).not.toBeNull();
    expect(a.style.getPropertyValue("--kit-avatar-color")).toMatch(/^var\(--kit-chart-[1-6]\)$/);
    expect(c.style.getPropertyValue("--kit-avatar-color")).toBe(a.style.getPropertyValue("--kit-avatar-color"));
    expect([a.getAttribute("role"), a.getAttribute("aria-label")]).toEqual(["img", "ada  de lovelace"]);
  });
  it("pages a table with external rows by data-kit-total and data-kit-page", async () => {
    document.body.innerHTML = '<table class="kit-table" id="x" data-kit-sort data-kit-pages="10" data-kit-rows="external" data-kit-total="35"><thead><tr><th>Name</th></tr></thead><tbody><tr><td>a</td></tr></tbody></table>';
    load(kitJs);
    await tick();
    const t = document.getElementById("x") as HTMLTableElement;
    const info = () => document.querySelector(".kit-pager__info")!.textContent;
    expect(info()).toBe("Page 1 of 4, 35 rows");
    const pages: string[] = [];
    t.addEventListener("kit:page", (e) => { const d = (e as CustomEvent).detail; pages.push(d.page + ":" + d.start + "-" + d.end); });
    (document.querySelectorAll(".kit-pager button")[1] as HTMLButtonElement).click();
    expect(pages).toEqual(["2:10-20"]);
    t.setAttribute("data-kit-page", "4");
    await tick();
    expect(info()).toBe("Page 4 of 4, 35 rows");
    expect((document.querySelectorAll(".kit-pager button")[1] as HTMLButtonElement).disabled).toBe(true);
  });
  it("fills cells from columns given in code: a format function, missing values and a date's sort value", async () => {
    document.body.innerHTML = '<table id="g"><tbody></tbody></table>';
    load(kitJs);
    await tick();
    const n = ui().fillTable("#g", [{ a: 5, d: "2026-01-02" }, { a: null, d: "" }], [{ key: "a", format: (v: unknown) => "<" + v + ">" }, { key: "a", missing: "?" }, { key: "d", format: "date" }]);
    expect(n).toBe(2);
    const rows = Array.from((document.getElementById("g") as HTMLTableElement).tBodies[0].rows).filter((r) => !r.hasAttribute("data-kit-empty"));
    expect(rows.map((r) => Array.from(r.cells).map((c) => c.className + "|" + c.textContent + "|" + (c.getAttribute("data-sort") ?? "none")))).toEqual([
      ["|<5>|none", "kit-num|5|5", "|2 Jan 2026|2026-01-02"],   // a format function of its own: not a number column
      ["|<null>|none", "|?|none", "|-|"]]);
  });
});

describe("kit-charts.js bar charts with a line series", () => {
  it("draws a line series over the bars, on its own axis at the right, named so in the legend", () => {
    const host = document.createElement("div");
    document.body.innerHTML = "";
    document.body.appendChild(host);
    if (!w.KitCharts) load(chartsJs);
    w.KitCharts.bar(host, { labels: ["Mon", "Tue", "Wed"], series: [{ name: "Rides", values: [3, 5, 4] }, { name: "Total", type: "line", axis: "right", values: [3, 8, 12] }] });
    expect(host.querySelectorAll(".kit-chart__bar").length).toBe(3);
    expect(host.querySelectorAll(".kit-chart__path").length).toBe(1);
    expect(host.querySelectorAll(".kit-chart__dot").length).toBe(3);
    expect(host.textContent).toContain("Total (right axis)");
    const right = Array.from(host.querySelectorAll("text.kit-chart__label")).filter((t) => (t as SVGTextElement).style.fill);
    expect(right.length).toBeGreaterThan(1);   // the right axis's values, in the line's colour
  });
});

describe("kit-icons-runtime.js", () => {
  it("draws icons before existing text and makes only a named, non-interactive icon an image", () => {
    const iconsJs = iconsRuntimeJs;
    (window as unknown as { KitIconData: Record<string, string> }).KitIconData = { plus: '<path d="M5 12h14"/>' };
    document.body.innerHTML = `<span id="img" data-kit-icon="plus" aria-label="Add"></span>
      <button id="btn" data-kit-icon="plus" aria-label="Add">New</button>
      <div id="tab" data-kit-icon="plus" aria-label="Add" tabindex="0"></div>
      <span id="role" data-kit-icon="plus" aria-label="Add" role="button"></span>
      <span id="plain" data-kit-icon="plus"></span>`;
    load(iconsJs);
    const el = (id: string) => document.getElementById(id) as HTMLElement;
    expect(el("img").getAttribute("role")).toBe("img");
    expect(el("btn").getAttribute("role")).toBeNull();
    expect(el("btn").firstElementChild?.tagName.toLowerCase()).toBe("svg");
    expect(el("btn").textContent).toBe("New");
    expect(el("tab").getAttribute("role")).toBeNull();
    expect(el("role").getAttribute("role")).toBe("button");
    expect(el("plain").getAttribute("role")).toBeNull();
    expect(el("plain").querySelector("svg")?.getAttribute("aria-hidden")).toBe("true");
    expect(el("plain").getAttribute("data-kit-icon-drawn")).toBe("plus");
  });
});

describe("kit.js tooltips, toast buttons, context menus and the command palette", () => {
  const press = (el: Element, key: string, more: KeyboardEventInit = {}) => {
    const e = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...more });
    el.dispatchEvent(e);
    return e;
  };
  const tip = () => document.querySelector<HTMLElement>(".kit-tooltip");
  afterEach(() => vi.useRealTimers());
  it("shows data-kit-tooltip instead of title: at once on keyboard focus, after a rest on hover, at once next to one that just closed, never after a tap", async () => {
    document.body.innerHTML = `<button id="ta" class="kit-btn kit-btn--icon" type="button" title="Edit" data-kit-tooltip="Edit"></button>
      <button id="tb" type="button" aria-label="Delete" data-kit-tooltip="Delete">x</button><span id="tc" tabindex="0" data-kit-tooltip="The whole long name">The whole...</span>`;
    load(kitJs);
    await tick();
    vi.useFakeTimers({ now: Date.now() + 60000 });
    const a = document.getElementById("ta")!, b = document.getElementById("tb")!, c = document.getElementById("tc")!;
    expect(a.getAttribute("title")).toBeNull();   // no second, browser-drawn tooltip
    expect(a.getAttribute("aria-label")).toBe("Edit");   // the name the title gave it
    a.focus();
    expect(tip()!.hidden).toBe(false);
    expect(tip()!.textContent).toBe("Edit");
    expect(tip()!.getAttribute("role")).toBe("tooltip");
    expect(a.getAttribute("aria-describedby")).toBeNull();   // it says the same as the name
    expect(press(a, "Escape").defaultPrevented).toBe(true);   // the tooltip only: a dialog around it stays open
    expect(tip()!.hidden).toBe(true);
    a.blur();
    vi.advanceTimersByTime(1000);
    b.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    vi.advanceTimersByTime(499);
    expect(tip()!.hidden).toBe(true);
    vi.advanceTimersByTime(1);
    expect(tip()!.hidden).toBe(false);
    expect(tip()!.textContent).toBe("Delete");
    b.dispatchEvent(new MouseEvent("mouseout", { bubbles: true, relatedTarget: c }));
    expect(tip()!.hidden).toBe(true);
    c.dispatchEvent(new MouseEvent("mouseover", { bubbles: true, relatedTarget: b }));
    expect(tip()!.hidden).toBe(false);   // a neighbour opens at once
    expect(c.getAttribute("aria-describedby")).toBe("kit-tooltip");
    c.dispatchEvent(new MouseEvent("mouseout", { bubbles: true }));
    expect(c.getAttribute("aria-describedby")).toBeNull();
    vi.advanceTimersByTime(2000);
    document.body.dispatchEvent(new Event("touchstart", { bubbles: true }));
    b.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    vi.advanceTimersByTime(1000);
    expect(tip()!.hidden).toBe(true);   // the mouse events after a tap show nothing
  });
  it("gives a toast a Dismiss button, and keeps it while the pointer is on it", () => {
    vi.useFakeTimers();
    const toast = (w.KitUI.toast as unknown as (text: string, o?: Record<string, unknown>) => HTMLElement);
    const t = toast("Saved");
    const x = t.querySelector<HTMLButtonElement>(".kit-toast__close")!;
    expect(x.getAttribute("aria-label")).toBe("Dismiss");
    expect(x.className).toBe("kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm kit-toast__close");
    t.dispatchEvent(new MouseEvent("mouseenter"));
    vi.advanceTimersByTime(20000);
    expect(t.classList.contains("is-leaving")).toBe(false);
    t.dispatchEvent(new MouseEvent("mouseleave"));
    vi.advanceTimersByTime(4100);
    expect(t.classList.contains("is-leaving")).toBe(true);
    expect(toast("Saved", { close: false }).querySelector(".kit-toast__close")).toBeNull();
    const u = toast("Sent");
    u.querySelector<HTMLButtonElement>(".kit-toast__close")!.click();
    expect(u.classList.contains("is-leaving")).toBe(true);
    vi.advanceTimersByTime(400);
    expect(u.parentNode).toBeNull();
  });
  it("opens a row's menu at the pointer on a right click and with Shift+F10, and names the row in kit:menu", async () => {
    document.body.innerHTML = `<ul><li id="row" data-kit-context><span id="name">Report</span><div class="kit-menu"><button id="more" type="button" data-kit-menu aria-haspopup="menu" aria-expanded="false" aria-label="Actions for Report">...</button>
      <div class="kit-menu__list" role="menu" hidden><button class="kit-menu__item" type="button" data-value="open">Open</button><button class="kit-menu__item" type="button" data-value="del">Delete</button></div></div></li></ul>
      <p id="away">Elsewhere</p>`;
    await tick();
    const row = document.getElementById("row")!, more = document.getElementById("more")!, list = document.querySelector<HTMLElement>(".kit-menu__list")!;
    const right = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 100, clientY: 50 });
    document.getElementById("name")!.dispatchEvent(right);
    expect(right.defaultPrevented).toBe(true);
    expect(list.hidden).toBe(false);
    expect([list.style.position, list.style.left, list.style.top]).toEqual(["fixed", "100px", "50px"]);
    expect(more.getAttribute("aria-expanded")).toBe("true");
    expect(document.activeElement!.textContent).toBe("Open");
    let got: { value?: string; target?: Element } = {};
    document.addEventListener("kit:menu", (e) => { got = (e as CustomEvent).detail; }, { once: true });
    list.querySelectorAll<HTMLButtonElement>(".kit-menu__item")[1].click();
    expect(got.value).toBe("del");
    expect(got.target).toBe(row);
    expect(list.hidden).toBe(true);
    expect(list.style.position).toBe("");   // back in its place for its own button
    more.focus();
    expect(press(more, "F10", { shiftKey: true }).defaultPrevented).toBe(true);
    expect(list.hidden).toBe(false);
    press(document.activeElement!, "Escape");
    expect(list.hidden).toBe(true);
    expect(document.activeElement).toBe(more);
    more.click();
    expect(list.hidden).toBe(false);
    expect(list.style.position).toBe("");
    document.getElementById("away")!.click();
    expect(list.hidden).toBe(true);
    const plain = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 5, clientY: 5 });
    document.getElementById("away")!.dispatchEvent(plain);
    expect(plain.defaultPrevented).toBe(false);   // the browser's own menu everywhere else
  });
  it("opens the command palette with Ctrl+K (not from a field), filters, runs a row with Enter, and clears the text before it closes", async () => {
    document.body.innerHTML = `<button id="start" type="button">Start</button><input id="field" aria-label="Name">
      <dialog class="kit-dialog kit-palette" id="pal" data-kit-palette aria-label="Commands"><div class="kit-input-icon"><input class="kit-input" type="search" placeholder="Type a command"></div>
      <ul class="kit-search__list"><li class="kit-search__item" data-value="new">New station<span class="kit-search__meta"><kbd class="kit-kbd">N</kbd></span></li><li class="kit-search__item" data-value="print">Print this page</li></ul>
      <p class="kit-empty" hidden>No commands match</p></dialog>`;
    await tick();
    const pal = document.getElementById("pal")!, input = pal.querySelector("input")!, list = pal.querySelector<HTMLElement>(".kit-search__list")!, empty = pal.querySelector<HTMLElement>(".kit-empty")!;
    const rows = Array.from(list.children) as HTMLElement[];
    expect(input.getAttribute("role")).toBe("combobox");
    expect(input.getAttribute("aria-label")).toBe("Commands");
    expect(input.getAttribute("aria-controls")).toBe(list.id);
    expect(list.getAttribute("role")).toBe("listbox");
    expect(press(document.getElementById("field")!, "k", { ctrlKey: true }).defaultPrevented).toBe(false);   // a field keeps Ctrl+K
    expect(pal.hasAttribute("open")).toBe(false);
    document.getElementById("start")!.focus();
    expect(press(document.getElementById("start")!, "k", { ctrlKey: true }).defaultPrevented).toBe(true);
    expect(pal.hasAttribute("open")).toBe(true);
    expect(document.activeElement).toBe(input);
    expect(input.getAttribute("aria-activedescendant")).toBe(rows[0].id);
    input.value = "print";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    expect(rows.map((r) => r.hidden)).toEqual([true, false]);
    expect(input.getAttribute("aria-activedescendant")).toBe(rows[1].id);
    let ran: { value?: string; text?: string } = {};
    pal.addEventListener("kit:command", (e) => { ran = (e as CustomEvent).detail; });
    press(input, "Enter");
    expect(ran).toEqual({ value: "print", text: "Print this page" });
    expect(pal.hasAttribute("open")).toBe(false);
    press(document.body, "k", { metaKey: true });
    expect(pal.hasAttribute("open")).toBe(true);
    expect(input.value).toBe("");
    press(input, "ArrowUp");
    expect(input.getAttribute("aria-activedescendant")).toBe(rows[1].id);   // round to the last row
    input.value = "zzz";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    expect([list.hidden, empty.hidden, input.getAttribute("aria-expanded")]).toEqual([true, false, "false"]);
    expect(press(input, "Escape").defaultPrevented).toBe(true);   // the text first
    expect(input.value).toBe("");
    expect(pal.hasAttribute("open")).toBe(true);
    press(input, "k", { ctrlKey: true });
    expect(pal.hasAttribute("open")).toBe(false);
  });
});
describe("kit.js shared element specs: disabled guard, hold, type-ahead, theme", () => {
  const press = (el: Element, key: string, more: KeyboardEventInit = {}) => el.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...more }));
  afterEach(() => { vi.useRealTimers(); });
  it("ignores presses and keys on an aria-disabled or busy control but keeps it focusable", async () => {
    document.body.innerHTML = '<button class="kit-btn" type="button" aria-disabled="true" id="off">Publish</button>' +
      '<button class="kit-btn" type="button" aria-busy="true" id="busy">Saving</button><button class="kit-btn" type="button" id="on">Save</button>';
    load(kitJs);
    await tick();
    const ran: string[] = [];
    for (const id of ["off", "busy", "on"]) document.getElementById(id)!.addEventListener("click", () => ran.push(id));
    for (const id of ["off", "busy", "on"]) document.getElementById(id)!.click();
    expect(ran).toEqual(["on"]);
    const off = document.getElementById("off") as HTMLButtonElement;
    off.focus();
    expect(document.activeElement).toBe(off);
    expect(press(off, "Enter").valueOf()).toBe(false);   // cancelled before any handler
    expect(press(off, "Tab").valueOf()).toBe(true);
  });
  it("leaves an aria-disabled field out of the form data", async () => {
    document.body.innerHTML = '<form id="f"><input name="a" value="1"><input name="b" value="2" aria-disabled="true" readonly></form>';
    load(kitJs);
    await tick();
    const form = document.getElementById("f") as HTMLFormElement;
    const data = new FormData(form);
    // jsdom sends no formdata event; send the one a browser sends while it builds the data.
    form.dispatchEvent(Object.assign(new Event("formdata", { bubbles: true }), { formData: data }));
    expect(data.get("a")).toBe("1");
    expect(data.get("b")).toBeNull();
  });
  it("starts a hold only on the main button, says the done word and stays full when done", async () => {
    document.body.innerHTML = '<button class="kit-btn kit-btn--hold" data-kit-hold="100" data-kit-hold-done="Deleted" type="button"><span data-kit-hold-label>Hold to delete</span></button>';
    load(kitJs);
    await tick();
    vi.useFakeTimers();
    const b = document.querySelector(".kit-btn--hold") as HTMLButtonElement;
    let held = 0;
    b.addEventListener("kit:hold", () => held++);
    b.dispatchEvent(new MouseEvent("pointerdown", { button: 2, bubbles: true }));
    expect(b.classList.contains("is-holding")).toBe(false);
    b.dispatchEvent(new MouseEvent("pointerdown", { button: 0, bubbles: true }));
    expect(b.classList.contains("is-holding")).toBe(true);
    vi.advanceTimersByTime(150);
    expect(held).toBe(1);
    expect(b.classList.contains("is-done")).toBe(true);
    expect(b.querySelector("[data-kit-hold-label]")!.textContent).toBe("Deleted");
    expect(press(b, " ", { repeat: true }).valueOf()).toBe(false);   // a repeating key does not start again
    expect(b.classList.contains("is-holding")).toBe(false);
  });
  it("does not start a hold on an aria-disabled hold button", async () => {
    document.body.innerHTML = '<button class="kit-btn kit-btn--hold" data-kit-hold="100" aria-disabled="true" type="button">Hold to delete</button>';
    load(kitJs);
    await tick();
    const b = document.querySelector(".kit-btn--hold") as HTMLButtonElement;
    b.dispatchEvent(new MouseEvent("pointerdown", { button: 0, bubbles: true }));
    expect(b.classList.contains("is-holding")).toBe(false);
  });
  it("jumps to a menu item or tree row by its first letters", async () => {
    document.body.innerHTML = '<div class="kit-menu"><button data-kit-menu aria-expanded="false" type="button">Actions</button><div class="kit-menu__list" hidden>' +
      '<button class="kit-menu__item" type="button">Edit</button><button class="kit-menu__item" type="button">Export</button><button class="kit-menu__item" type="button">Delete</button></div></div>' +
      '<ul class="kit-tree" data-kit-tree aria-label="Folders"><li><span class="kit-tree__row">Alpha</span></li><li><span class="kit-tree__row">Beta</span></li></ul>';
    load(kitJs);
    await tick();
    const items = Array.from(document.querySelectorAll(".kit-menu__item")) as HTMLButtonElement[];
    (document.querySelector("[data-kit-menu]") as HTMLButtonElement).click();
    expect(document.activeElement).toBe(items[0]);
    press(items[0], "d");
    expect(document.activeElement).toBe(items[2]);
    press(items[2], "e");
    expect(document.activeElement).toBe(items[2]);   // "de" typed together still names Delete
    const rows = Array.from(document.querySelectorAll(".kit-tree__row")) as HTMLElement[];
    vi.useFakeTimers();
    vi.setSystemTime(Date.now() + 1000);   // past the 600 ms in which typed letters add up
    rows[0].focus();
    press(rows[0], "b");
    expect(document.activeElement).toBe(rows[1]);
  });
  it("updates every theme button on the page when one is pressed", async () => {
    document.documentElement.setAttribute("data-theme", "light");
    document.body.innerHTML = '<button class="kit-btn" type="button" data-kit-theme id="t1"></button><button class="kit-btn" type="button" data-kit-theme id="t2"></button>';
    load(kitJs);
    await tick();
    (document.getElementById("t1") as HTMLButtonElement).click();
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    expect(document.documentElement.hasAttribute("data-kit-theme-switching")).toBe(true);
    expect(document.getElementById("t2")!.getAttribute("aria-label")).toBe("Switch to the light theme");
    document.documentElement.removeAttribute("data-theme");
    document.documentElement.removeAttribute("data-kit-theme-switching");
    try { localStorage.removeItem("kit-theme"); } catch { /* jsdom storage */ }
  });
});
describe("kit.js forms and touch parts (kit revision 17)", () => {
  type Check = { value: string; display: string; ok: boolean; message: string; suggestion?: string; brand?: string };
  const kit = () => (window as unknown as { KitUI: { check: (kind: string, text: string, opts?: Record<string, unknown>) => Check } }).KitUI;
  const key = (el: Element, k: string, more: KeyboardEventInit = {}) => el.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...more }));
  const events = (el: Element, name: string) => { const got: Record<string, unknown>[] = []; el.addEventListener(name, (e) => got.push((e as CustomEvent).detail)); return got; };
  const box = (width: number) => ({ width, height: 20, top: 0, left: 0, right: width, bottom: 20, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
  afterEach(() => { vi.useRealTimers(); document.documentElement.lang = ""; });

  it("listbox: one tab stop, arrows move and pick, an aria-disabled option is never picked, kit:select and the form value", async () => {
    document.body.innerHTML = '<form><ul class="kit-listbox" role="listbox" data-kit-listbox data-name="owner" aria-label="Owner">' +
      '<li class="kit-option" role="option" data-value="ana"><span class="kit-option__label">Ana Lima</span><span class="kit-option__meta">Design</span></li>' +
      '<li class="kit-option" role="option" data-value="bo" aria-disabled="true">Bo Lee</li><li class="kit-option" role="option" data-value="cy">Cy Park</li></ul></form>';
    load(kitJs);
    await tick();
    const lb = document.querySelector(".kit-listbox") as HTMLElement;
    const got = events(lb, "kit:select");
    expect(lb.tabIndex).toBe(0);
    lb.focus();
    key(lb, "ArrowDown");
    expect(lb.getAttribute("aria-activedescendant")).toBe(lb.children[1].id);
    expect(lb.children[1].getAttribute("aria-selected")).toBe("false");   // aria-disabled: reached, not picked
    key(lb, "ArrowDown");
    expect(lb.children[2].getAttribute("aria-selected")).toBe("true");   // one choice follows the move
    (lb.children[1] as HTMLElement).click();
    expect(lb.children[1].getAttribute("aria-selected")).toBe("false");
    vi.useFakeTimers();
    vi.setSystemTime(Date.now() + 5000);   // past the 600 ms in which an earlier test's letters add up
    key(lb, "a");
    expect(lb.children[0].getAttribute("aria-selected")).toBe("true");   // typed letters
    expect(got[got.length - 1]).toMatchObject({ value: "ana", values: ["ana"] });
    expect(new FormData(document.querySelector("form") as HTMLFormElement).getAll("owner")).toEqual(["ana"]);
  });

  it("listbox in a popover: a pick closes it and shows the label on its button", async () => {
    document.body.innerHTML = '<div class="kit-popover-wrap"><button class="kit-select" type="button" data-kit-popover="pl" aria-expanded="false"><span data-kit-listbox-value>Choose</span></button>' +
      '<div class="kit-popover" id="pl" hidden><ul class="kit-listbox" role="listbox" data-kit-listbox aria-label="Owner"><li class="kit-option" role="option">Ana Lima</li><li class="kit-option" role="option">Bo Lee</li></ul></div></div>';
    load(kitJs);
    await tick();
    const btn = document.querySelector("[data-kit-popover]") as HTMLButtonElement;
    expect(btn.getAttribute("aria-haspopup")).toBe("listbox");
    btn.click();
    const lb = document.querySelector(".kit-listbox") as HTMLElement;
    expect(document.activeElement).toBe(lb);
    key(lb, "ArrowDown");
    expect(lb.children[1].getAttribute("aria-selected")).toBe("false");   // in a popover the move does not pick
    key(lb, "Enter");
    expect(btn.querySelector("[data-kit-listbox-value]")!.textContent).toBe("Bo Lee");
    expect(btn.getAttribute("aria-expanded")).toBe("false");
    expect(document.activeElement).toBe(btn);
  });

  it("number field: a spinbutton that steps, keeps within min and max, reads a decimal comma and disables a step at its bound", async () => {
    document.documentElement.lang = "nl";
    document.body.innerHTML = '<form><div class="kit-number"><button class="kit-number__step" type="button" data-kit-nudge="-1">-</button>' +
      '<input class="kit-input" id="n" data-kit-number min="0" max="10" step="0.5" value="9" name="qty" aria-label="Amount"><button class="kit-number__step" type="button" data-kit-nudge="1">+</button></div></form>';
    load(kitJs);
    await tick();
    const input = document.getElementById("n") as HTMLInputElement;
    const [less, more] = Array.from(document.querySelectorAll(".kit-number__step")) as HTMLButtonElement[];
    const got = events(input, "kit:change");
    expect(input.getAttribute("role")).toBe("spinbutton");
    expect(input.getAttribute("aria-valuenow")).toBe("9");
    expect(more.tabIndex).toBe(-1);
    key(input, "ArrowUp");
    key(input, "ArrowUp");
    key(input, "ArrowUp");
    expect(input.getAttribute("aria-valuenow")).toBe("10");   // kept at max
    expect(more.getAttribute("aria-disabled")).toBe("true");
    more.click();
    expect(got.length).toBe(2);
    key(input, "Home");
    expect(input.getAttribute("aria-valuenow")).toBe("0");
    expect(less.getAttribute("aria-disabled")).toBe("true");
    input.value = "7,5 kg";
    input.dispatchEvent(new Event("blur"));
    expect(input.getAttribute("aria-valuenow")).toBe("7.5");
    expect(input.value).toBe("7,5");
    expect(new FormData(document.querySelector("form") as HTMLFormElement).get("qty")).toBe("7.5");
    input.value = "seven";
    input.dispatchEvent(new Event("blur"));
    expect(input.getAttribute("aria-invalid")).toBe("true");
    expect(input.value).toBe("seven");   // kept as typed, with a message
    expect(document.getElementById(input.getAttribute("aria-describedby")!)!.textContent).toMatch(/Use a number, like 12 or 3,5/);
  });

  it("typed field checks: email hint, phone, IBAN, card, postcode, amount and code", async () => {
    document.body.innerHTML = "";
    load(kitJs);
    await tick();
    const k = kit();
    expect(k.check("email", "ana@gmial.com")).toMatchObject({ ok: true, suggestion: "ana@gmail.com" });
    expect(k.check("email", "ana.studio.example").ok).toBe(false);
    expect(k.check("phone", "020 123 4567", { callingCode: "31" })).toMatchObject({ ok: true, value: "+31201234567", display: "+31 201 234 567" });   // stored international, shown in threes
    expect(k.check("phone", "020 123 4567").message).toMatch(/country code/);
    expect(k.check("iban", "nl74 exmp 0123 4567 89")).toMatchObject({ ok: true, value: "NL74EXMP0123456789", display: "NL74 EXMP 0123 4567 89" });
    expect(k.check("iban", "NL75EXMP0123456789").message).toMatch(/typo/);
    expect(k.check("card", "4111-1111-1111-1111")).toMatchObject({ ok: true, value: "4111111111111111", brand: "visa" });
    expect(k.check("card", "4111 1111 1111 1112").ok).toBe(false);
    expect(k.check("postcode", "1234ab", { country: "NL" })).toMatchObject({ ok: true, value: "1234 AB" });
    expect(k.check("postcode", "123", { country: "US" }).message).toMatch(/ZIP codes in/);
    expect(k.check("postcode", "", { country: "HK" }).ok).toBe(true);   // no postcodes there
    document.documentElement.lang = "nl";
    expect(k.check("amount", "1.250,5")).toMatchObject({ ok: true, value: "1250.50", display: "1.250,50" });
    expect(k.check("code", "12 34 5").message).toMatch(/6 digits; this has 5/);
    expect(k.check("new-password", "short", { min: 12 }).ok).toBe(false);
  });

  it("typed fields in a form: the submit stops on the first error, a closed section opens, the form sends the clean value", async () => {
    document.body.innerHTML = '<form id="f" novalidate><div class="kit-disclosure" data-kit-disclosure><h3 class="kit-disclosure__heading"><button class="kit-disclosure__head" type="button" aria-expanded="false" aria-controls="p1">Contact</button></h3>' +
      '<div class="kit-disclosure__panel" id="p1"><div class="kit-disclosure__body"><div class="kit-field"><input class="kit-input" id="m" name="email" data-kit-field="email" required></div>' +
      '<div class="kit-field"><input class="kit-input" id="ph" name="phone" data-kit-field="phone" data-calling-code="31" value="020 123 4567"></div></div></div></div><button type="submit">Send</button></form>';
    load(kitJs);
    await tick();
    const form = document.getElementById("f") as HTMLFormElement, mail = document.getElementById("m") as HTMLInputElement;
    let sent = 0;
    form.addEventListener("submit", (e) => { e.preventDefault(); sent++; });
    expect(document.getElementById("p1")!.hasAttribute("inert")).toBe(true);
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    expect(sent).toBe(0);
    expect(mail.getAttribute("aria-invalid")).toBe("true");
    expect(document.getElementById("p1")!.getAttribute("data-state")).toBe("open");
    expect(document.activeElement).toBe(mail);
    expect(document.getElementById(mail.getAttribute("aria-describedby")!)!.textContent).toMatch(/Enter an email address/);
    mail.value = "ana@studio.example";
    mail.dispatchEvent(new Event("input", { bubbles: true }));
    expect(mail.hasAttribute("aria-invalid")).toBe(false);   // typing clears a fixed error
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    expect(sent).toBe(1);
    expect((document.getElementById("ph") as HTMLInputElement).value).toBe("+31 201 234 567");
    const data = new FormData(form);
    form.dispatchEvent(Object.assign(new Event("formdata", { bubbles: true }), { formData: data }));
    expect(data.get("phone")).toBe("+31201234567");
  });

  it("password: adds a named reveal toggle that keeps focus, and hides the value again on submit", async () => {
    document.body.innerHTML = '<form id="f"><div class="kit-field"><div class="kit-input-group kit-password" data-kit-password><input class="kit-input" id="pw" type="password" minlength="12" maxlength="20" autocomplete="off"></div></div></form>';
    load(kitJs);
    await tick();
    const pw = document.getElementById("pw") as HTMLInputElement, btn = document.querySelector("[data-kit-reveal]") as HTMLButtonElement;
    expect(btn.getAttribute("aria-label")).toBe("Show password");
    expect(pw.getAttribute("autocomplete")).toBe("new-password");
    expect(pw.hasAttribute("maxlength")).toBe(false);
    expect(document.getElementById(pw.getAttribute("aria-describedby")!)!.textContent).toMatch(/At least 12 characters/);
    pw.focus();
    btn.click();
    expect(pw.type).toBe("text");
    expect(btn.getAttribute("aria-pressed")).toBe("true");
    expect(document.activeElement).toBe(pw);
    document.getElementById("f")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    expect(pw.type).toBe("password");
  });

  it("one-time code: a pasted code spreads over the boxes and the joined digits go with the form", async () => {
    document.body.innerHTML = '<form><div class="kit-otp" data-kit-otp data-name="code"><input class="kit-input kit-otp__box"><input class="kit-input kit-otp__box"><input class="kit-input kit-otp__box"><input class="kit-input kit-otp__box"></div></form>';
    load(kitJs);
    await tick();
    const boxes = Array.from(document.querySelectorAll(".kit-otp__box")) as HTMLInputElement[];
    const got = events(document.querySelector(".kit-otp")!, "kit:code");
    expect(boxes[0].getAttribute("autocomplete")).toBe("one-time-code");
    expect(boxes[2].getAttribute("aria-label")).toBe("Digit 3 of 4");
    boxes[0].value = "12 34";
    boxes[0].dispatchEvent(new Event("input", { bubbles: true }));
    expect(boxes.map((b) => b.value)).toEqual(["1", "2", "3", "4"]);
    expect(got[got.length - 1]).toMatchObject({ value: "1234", complete: true });
    expect(new FormData(document.querySelector("form") as HTMLFormElement).get("code")).toBe("1234");
    boxes[3].value = "";
    boxes[3].focus();
    key(boxes[3], "Backspace");
    expect(document.activeElement).toBe(boxes[2]);
    expect(boxes[2].value).toBe("");
  });

  it("address: the country decides the postcode and region fields", async () => {
    document.body.innerHTML = '<form><fieldset data-kit-address><div class="kit-field"><select id="c" autocomplete="country"><option value="US">United States</option><option value="HK">Hong Kong</option><option value="NL">Netherlands</option></select></div>' +
      '<div class="kit-field"><label class="kit-label" for="r">Region</label><input id="r" name="region" autocomplete="address-level1"></div>' +
      '<div class="kit-field"><label class="kit-label" for="p">Postcode</label><input id="p" name="postcode" autocomplete="postal-code" data-kit-field="postcode"></div></fieldset></form>';
    load(kitJs);
    await tick();
    const sel = document.getElementById("c") as HTMLSelectElement, pc = document.getElementById("p") as HTMLInputElement;
    expect(document.querySelector('label[for="p"]')!.textContent).toBe("ZIP code");
    expect(document.querySelector('label[for="r"]')!.textContent).toBe("State");
    expect((document.getElementById("r") as HTMLInputElement).required).toBe(true);
    sel.value = "HK";
    sel.dispatchEvent(new Event("change", { bubbles: true }));
    expect(pc.closest(".kit-field")!.hasAttribute("hidden")).toBe(true);
    expect(pc.hasAttribute("name")).toBe(false);   // a hidden field sends nothing
    sel.value = "NL";
    sel.dispatchEvent(new Event("change", { bubbles: true }));
    expect(pc.getAttribute("name")).toBe("postcode");
    expect(pc.getAttribute("placeholder")).toBe("1234 AB");
    expect(document.getElementById("r")!.closest(".kit-field")!.hasAttribute("hidden")).toBe(true);
  });

  it("date range: presets apply on pick, custom dates are swapped and checked against min, kit:range", async () => {
    document.body.innerHTML = '<div class="kit-daterange" data-kit-daterange data-value="7d" data-presets="7d,30d,all" data-min="2026-01-01" aria-label="Period"></div>';
    load(kitJs);
    await tick();
    const el = document.querySelector(".kit-daterange") as HTMLElement, trigger = el.querySelector("button") as HTMLButtonElement;
    const got = events(el, "kit:range");
    expect(trigger.getAttribute("aria-label")).toBe("Period, Last 7 days");
    trigger.click();
    const panel = document.getElementById(trigger.getAttribute("data-kit-popover")!)!;
    expect(panel.hidden).toBe(false);
    (panel.querySelector('[data-preset="all"]') as HTMLButtonElement).click();
    expect(got[0]).toMatchObject({ preset: "all", from: "", to: "" });
    expect(panel.hidden).toBe(true);
    trigger.click();
    const [from, to] = Array.from(panel.querySelectorAll('input[type="date"]')) as HTMLInputElement[];
    from.value = "2026-03-10";
    to.value = "2026-03-01";
    (panel.querySelector(".kit-btn--primary") as HTMLButtonElement).click();
    expect(got[1]).toMatchObject({ preset: "custom", from: "2026-03-01", to: "2026-03-10" });
    trigger.click();
    from.value = "2025-12-01";
    key(from, "Enter");
    expect(got.length).toBe(2);
    expect(from.getAttribute("aria-invalid")).toBe("true");
  });

  it("sheet: opens on its lowest stop, steps through the stops and closes on a flick down", async () => {
    document.body.innerHTML = '<button type="button" data-kit-open="sh">Open</button><dialog class="kit-sheet" id="sh" data-kit-sheet data-detents="0.3 0.9"><div class="kit-sheet__grab"><span class="kit-sheet__handle"></span>' +
      '<div class="kit-sheet__head"><h2 class="kit-sheet__title">Stops</h2><button type="button" data-kit-detent aria-expanded="false">Expand</button></div></div><div class="kit-sheet__body">x</div></dialog>';
    load(kitJs);
    await tick();
    const d = document.getElementById("sh") as HTMLDialogElement, step = d.querySelector("[data-kit-detent]") as HTMLButtonElement;
    const got = events(d, "kit:detent");
    (document.querySelector("[data-kit-open]") as HTMLButtonElement).click();
    expect(d.open).toBe(true);
    expect(got[0]).toMatchObject({ index: 0 });
    expect(d.style.transform).toMatch(/translateY\([1-9]\d*px\)/);   // the lower stop is a position, not a smaller sheet
    step.click();
    expect(got[1]).toMatchObject({ index: 1 });
    expect(step.getAttribute("aria-expanded")).toBe("true");
    expect(d.style.transform).toBe("translateY(0px)");
    step.click();
    const grab = d.querySelector(".kit-sheet__grab")!;
    grab.dispatchEvent(new MouseEvent("pointerdown", { button: 0, clientY: 100, bubbles: true }));
    d.dispatchEvent(new MouseEvent("pointermove", { clientY: 400, bubbles: true }));
    d.dispatchEvent(new MouseEvent("pointerup", { clientY: 400, bubbles: true }));
    expect(d.open).toBe(false);   // pulled past half below the lowest stop
  });

  it("carousel: the buttons follow the scroll, the track keys move, the position is written", async () => {
    document.body.innerHTML = '<section class="kit-carousel" data-kit-carousel aria-label="Reports"><div class="kit-carousel__head"><h2>R</h2><span class="kit-carousel__pos"></span>' +
      '<button type="button" data-kit-prev aria-label="Previous">p</button><button type="button" data-kit-next aria-label="Next">n</button></div><ul class="kit-carousel__track"><li class="kit-carousel__item">a</li><li class="kit-carousel__item">b</li><li class="kit-carousel__item">c</li></ul></section>';
    const track = document.querySelector(".kit-carousel__track") as HTMLElement;
    Object.defineProperty(track, "scrollTo", { value: undefined });
    Object.defineProperty(track, "scrollLeft", { value: 0, writable: true });
    Object.defineProperty(track, "clientWidth", { value: 200 });
    Object.defineProperty(track, "scrollWidth", { value: 600 });
    Array.from(track.children).forEach((it, i) => { Object.defineProperty(it, "offsetLeft", { value: i * 200 }); Object.defineProperty(it, "offsetWidth", { value: 200 }); });
    load(kitJs);
    await tick();
    const prev = document.querySelector("[data-kit-prev]") as HTMLButtonElement, next = document.querySelector("[data-kit-next]") as HTMLButtonElement;
    expect(track.tabIndex).toBe(0);
    expect(prev.getAttribute("aria-disabled")).toBe("true");
    expect(track.getAttribute("data-more")).toBe("end");
    expect(document.querySelector(".kit-carousel__pos")!.textContent).toBe("1 of 3");
    next.click();
    expect(track.scrollLeft).toBe(200);
    expect(prev.hasAttribute("aria-disabled")).toBe(false);
    key(track, "End");
    expect(next.getAttribute("aria-disabled")).toBe("true");
    key(track, "ArrowLeft");
    expect(track.scrollLeft).toBe(200);
  });

  it("reorder: Space picks up, arrows move, Space drops; Escape cancels; Alt+arrow moves at once", async () => {
    document.body.innerHTML = '<ul class="kit-list kit-reorder" data-kit-reorder aria-label="Agenda">' + ["a", "b", "c"].map((id) =>
      `<li class="kit-list__item" data-id="${id}"><button type="button" data-kit-handle aria-label="Move ${id}">=</button><span class="kit-list__title">${id}</span></li>`).join("") + "</ul>";
    load(kitJs);
    await tick();
    const list = document.querySelector(".kit-reorder") as HTMLElement;
    const order = () => Array.from(list.querySelectorAll("[data-id]")).map((r) => r.getAttribute("data-id")).join("");
    const handle = (id: string) => list.querySelector(`[data-id="${id}"] [data-kit-handle]`) as HTMLButtonElement;
    const got = events(list, "kit:reorder");
    handle("a").focus();
    key(handle("a"), " ");
    expect(list.querySelector('[data-id="a"]')!.classList.contains("is-moving")).toBe(true);
    key(handle("a"), "ArrowDown");
    key(handle("a"), "ArrowDown");
    key(handle("a"), " ");
    expect(order()).toBe("bca");
    expect(got[0]).toMatchObject({ id: "a", from: 0, to: 2 });
    expect(document.activeElement).toBe(handle("a"));
    key(handle("a"), " ");
    key(handle("a"), "ArrowUp");
    key(handle("a"), "Escape");
    expect(order()).toBe("bca");
    key(handle("b"), "ArrowDown", { altKey: true });
    expect(order()).toBe("cba");
  });

  it("swipe actions: a mouse never swipes; a delete hides the row with Undo, and Undo brings it back", async () => {
    document.body.innerHTML = '<ul data-kit-swipe><li class="kit-swipe" data-name="Dock 4 stuck"><div class="kit-swipe__actions"><button class="kit-swipe__action" type="button" data-value="delete" data-remove="Message deleted">Delete</button></div>' +
      '<div class="kit-swipe__row">Dock 4 stuck</div></li></ul>';
    load(kitJs);
    await tick();
    const li = document.querySelector(".kit-swipe") as HTMLElement, row = li.querySelector(".kit-swipe__row") as HTMLElement, act = li.querySelector(".kit-swipe__action") as HTMLButtonElement;
    const got = events(li, "kit:swipe");
    expect(act.getAttribute("aria-label")).toBe("Delete Dock 4 stuck");
    expect(li.querySelector(".kit-swipe__actions")!.hasAttribute("inert")).toBe(true);
    row.dispatchEvent(Object.assign(new MouseEvent("pointerdown", { clientX: 200, bubbles: true }), { pointerType: "mouse" }));
    document.dispatchEvent(Object.assign(new MouseEvent("pointermove", { clientX: 50, bubbles: true }), { pointerType: "mouse" }));
    expect(row.style.transform).toBe("");
    act.click();
    expect(li.hidden).toBe(true);
    expect(got[0]).toMatchObject({ value: "delete", state: "removed" });
    const undo = Array.from(document.querySelectorAll(".kit-toast__action")).pop() as HTMLButtonElement;
    expect(undo.textContent).toBe("Undo");
    undo.click();
    expect(li.hidden).toBe(false);
    expect(got[1]).toMatchObject({ state: "restored" });
  });

  it("splitter: arrows, Home, Enter folding and back, kit:resize once per change; aria-disabled keeps the size", async () => {
    document.body.innerHTML = '<div class="kit-splitpane"><div class="kit-splitpane__pane" id="side">s</div><div class="kit-splitter" aria-controls="side" aria-label="Resize" data-kit-splitter data-min="100" data-max="500" data-default="300" data-persist="t1"></div><div class="kit-splitpane__pane">m</div></div>';
    load(kitJs);
    await tick();
    const bar = document.querySelector(".kit-splitter") as HTMLElement, pane = document.getElementById("side") as HTMLElement;
    const got = events(bar, "kit:resize");
    expect(bar.getAttribute("role")).toBe("separator");
    expect(bar.getAttribute("aria-valuenow")).toBe("300");
    key(bar, "ArrowRight");
    expect(pane.style.flexBasis).toBe("316px");
    key(bar, "ArrowLeft", { shiftKey: true });
    expect(bar.getAttribute("aria-valuenow")).toBe("252");
    key(bar, "Enter");
    expect(bar.getAttribute("aria-valuenow")).toBe("100");
    key(bar, "Enter");
    expect(bar.getAttribute("aria-valuenow")).toBe("252");
    key(bar, "End");
    expect(got.map((g) => g.size)).toEqual([316, 252, 100, 252, 500]);
    expect(localStorage.getItem("kit-split:t1")).toBe("500");
    bar.setAttribute("aria-disabled", "true");
    key(bar, "Home");
    expect(bar.getAttribute("aria-valuenow")).toBe("500");
    localStorage.removeItem("kit-split:t1");
  });

  it("disclosure: toggles with aria-expanded, a closed panel is inert, data-single keeps one open", async () => {
    document.body.innerHTML = '<div class="kit-disclosure" data-kit-disclosure data-single>' + [1, 2].map((i) =>
      `<h3 class="kit-disclosure__heading"><button class="kit-disclosure__head" type="button" aria-expanded="${i === 1}" aria-controls="dp${i}">S${i}</button></h3><div class="kit-disclosure__panel" id="dp${i}"><div class="kit-disclosure__body">b</div></div>`).join("") + "</div>";
    load(kitJs);
    await tick();
    const [b1, b2] = Array.from(document.querySelectorAll(".kit-disclosure__head")) as HTMLButtonElement[];
    const got = events(document.querySelector(".kit-disclosure")!, "kit:toggle");
    expect(document.getElementById("dp1")!.hasAttribute("inert")).toBe(false);
    expect(document.getElementById("dp2")!.hasAttribute("inert")).toBe(true);
    b2.click();
    expect(b2.getAttribute("aria-expanded")).toBe("true");
    expect(b1.getAttribute("aria-expanded")).toBe("false");
    expect(document.getElementById("dp1")!.getAttribute("data-state")).toBe("closed");
    expect(got.map((g) => g.open)).toEqual([false, true]);
  });

  it("toolbar overflow: buttons that do not fit fold into More in order, the primary stays, a menu item presses its button", async () => {
    document.body.innerHTML = '<div class="kit-toolbar kit-overflow" role="toolbar" aria-label="Actions" data-kit-overflow data-more-label="More actions">' +
      '<button class="kit-btn kit-btn--primary" type="button">Share</button><button class="kit-btn" type="button" aria-pressed="false">Totals</button><button class="kit-btn" type="button">Export</button><button class="kit-btn" type="button" data-priority="low">Print</button></div>';
    const row = document.querySelector(".kit-overflow") as HTMLElement;
    Object.defineProperty(row, "clientWidth", { value: 260 });
    Array.from(row.children).forEach((c) => { (c as HTMLElement).getBoundingClientRect = () => box(80); });
    const OrigDiv = HTMLDivElement.prototype.getBoundingClientRect;
    HTMLDivElement.prototype.getBoundingClientRect = function () { return this.classList.contains("kit-overflow__more") ? box(40) : OrigDiv.call(this); };
    load(kitJs);
    await tick();
    HTMLDivElement.prototype.getBoundingClientRect = OrigDiv;
    const [share, totals, exp, print] = Array.from(row.querySelectorAll(":scope > button")) as HTMLButtonElement[];
    const more = row.querySelector(".kit-overflow__more") as HTMLElement;
    expect(more.hidden).toBe(false);
    expect(share.hidden).toBe(false);
    expect(print.hidden).toBe(true);   // low priority first
    expect(exp.hidden).toBe(true);
    expect(totals.hidden).toBe(false);
    const moreBtn = more.querySelector("[data-kit-menu]") as HTMLButtonElement;
    expect(moreBtn.getAttribute("aria-label")).toBe("More actions");
    moreBtn.click();
    const items = Array.from(more.querySelectorAll(".kit-menu__item")) as HTMLButtonElement[];
    expect(items.map((i) => i.textContent)).toEqual(["Export", "Print"]);   // in the row's order
    let printed = 0;
    print.addEventListener("click", () => printed++);
    items[1].click();
    expect(printed).toBe(1);
  });

  it("breadcrumbs: the middle levels fold into a menu after the first until the trail fits", async () => {
    document.body.innerHTML = '<nav class="kit-breadcrumbs" aria-label="Breadcrumb" data-kit-breadcrumbs><ol>' + ["Home", "Region", "Station", "Docks"].map((t) => `<li><a href="#${t}">${t}</a></li>`).join("") + "<li>Dock 4</li></ol></nav>";
    const ol = document.querySelector("ol") as HTMLElement;
    Object.defineProperty(ol, "clientWidth", { value: 350 });
    Object.defineProperty(ol, "scrollWidth", { get: () => Array.from(ol.children).filter((c) => !(c as HTMLElement).hidden).reduce((s, c) => s + ((c as HTMLElement).className ? 40 : 100), 0) });
    load(kitJs);
    await tick();
    const levels = Array.from(ol.children) as HTMLElement[];
    expect(levels[levels.length - 1].getAttribute("aria-current")).toBe("page");
    const more = ol.querySelector(".kit-breadcrumbs__more") as HTMLElement;
    expect(more.hidden).toBe(false);
    expect(levels.filter((l) => l.hidden).map((l) => l.textContent)).toEqual(["Region", "Station"]);
    const links = Array.from(more.querySelectorAll("a.kit-menu__item")).map((a) => a.textContent);
    expect(links).toEqual(["Region", "Station"]);
    expect(more.querySelector("button")!.getAttribute("aria-label")).toBe("Show 2 more levels");
  });
});
