// @vitest-environment jsdom
// The UI kit's page behaviour (templates/ui-kit/kit.js) and charts (kit-charts.js) in a browser-like
// document: tables, search, the parts' accessibility, and what a chart does with odd data.
import fs from "node:fs";
import path from "node:path";
import { beforeAll, describe, expect, it } from "vitest";

const repo = path.resolve(import.meta.dirname, "../../..");
const kitJs = fs.readFileSync(path.join(repo, "templates/ui-kit/kit.js"), "utf8");
const chartsJs = fs.readFileSync(path.join(repo, "templates/ui-kit/kit-charts.js"), "utf8");

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
});

type KitFormat = { number: (v: unknown, o?: { decimals?: number }) => string; percent: (v: unknown, d?: number) => string; date: (v: unknown, o?: { time?: boolean }) => string; relative: (v: unknown) => string };
type KitTable = HTMLTableElement & { kitSelected: () => HTMLTableRowElement[]; kitSelect: (on: boolean) => void };

describe("kit.js additions", () => {
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
});

describe("page check: kit classes without a rule", () => {
  const pageCheck = fs.readFileSync(path.join(repo, "lib/page-content-check.js"), "utf8");
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
