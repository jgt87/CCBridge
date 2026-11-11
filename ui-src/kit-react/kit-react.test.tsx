// @vitest-environment jsdom
// The UI kit's React parts (templates/ui-kit/react), which StreamHub copies into people's React
// projects: what the keys, clicks and drags do. Rendered with React's own act in jsdom.
import { act, type ReactNode, useEffect, useRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { AppShell } from "../../templates/ui-kit/react/AppShell";
import { Board, type BoardCard } from "../../templates/ui-kit/react/Board";
import { Calendar } from "../../templates/ui-kit/react/Calendar";
import { CommandPalette } from "../../templates/ui-kit/react/CommandPalette";
import { useConfirm } from "../../templates/ui-kit/react/Confirm";
import { Drawer } from "../../templates/ui-kit/react/Drawer";
import { HoldButton } from "../../templates/ui-kit/react/HoldButton";
import { Menu } from "../../templates/ui-kit/react/Menu";
import { Popover } from "../../templates/ui-kit/react/Popover";
import { Tabs } from "../../templates/ui-kit/react/Tabs";
import { TagInput } from "../../templates/ui-kit/react/TagInput";
import { ThemeToggle } from "../../templates/ui-kit/react/ThemeToggle";
import { Toaster, toast } from "../../templates/ui-kit/react/Toast";
import { Tooltip } from "../../templates/ui-kit/react/Tooltip";
import { Tree, type TreeNode } from "../../templates/ui-kit/react/Tree";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
// Icon.tsx loads kit-icons.js, which StreamHub writes into each project: a stand-in that shows the icon's name.
vi.mock("../../templates/ui-kit/react/Icon", () => ({ Icon: ({ name }: { name: string }) => <span data-icon={name} /> }));

let root: Root | null = null;
let host: HTMLDivElement | null = null;

function render(ui: ReactNode) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  act(() => root!.render(ui));
  return host;
}
const rerender = (ui: ReactNode) => act(() => root!.render(ui));

afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
  root = null;
  host = null;
  vi.useRealTimers();
});

const $ = <T extends Element = HTMLElement>(sel: string) => document.querySelector<T>(sel)!;
const $$ = <T extends Element = HTMLElement>(sel: string) => Array.from(document.querySelectorAll<T>(sel));

/** A key on an element; returns whether the part took it (preventDefault). */
function key(el: Element, k: string, opts: KeyboardEventInit = {}) {
  const e = new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...opts });
  act(() => {
    el.dispatchEvent(e);
  });
  return e.defaultPrevented;
}
const click = (el: Element) => act(() => (el as HTMLElement).click());
const fire = (el: Element, type: string, props: Record<string, unknown> = {}) => {
  const e = new Event(type, { bubbles: true, cancelable: true });
  for (const [k, v] of Object.entries(props)) Object.defineProperty(e, k, { value: v });
  act(() => {
    el.dispatchEvent(e);
  });
  return e;
};
/** Types into a controlled input the way React notices (the native setter, then an input event). */
function typeInto(el: HTMLInputElement, text: string) {
  const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  act(() => {
    set.call(el, text);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

describe("Tree", () => {
  const nodes: TreeNode[] = [
    { value: "a", label: "A", children: [{ value: "a1", label: "A1" }, { value: "a2", label: "A2" }] },
    { value: "b", label: "B" },
  ];
  const row = (v: string) => $(`li[data-value="${v}"] > .kit-tree__row`);
  const focused = () => document.activeElement?.parentElement?.getAttribute("data-value");

  it("moves between the rows a person can reach, skipping closed branches", () => {
    render(<Tree label="Files" nodes={nodes} onSelect={() => {}} />);
    expect(row("a").tabIndex).toBe(0);
    expect(row("b").tabIndex).toBe(-1);
    key(row("a"), "ArrowDown");
    expect(focused()).toBe("b");
    key(row("b"), "Home");
    expect(focused()).toBe("a");
    key(row("a"), "End");
    expect(focused()).toBe("b");
  });

  it("opens a branch with Right, goes into it with Right again, and back up with Left", () => {
    render(<Tree label="Files" nodes={nodes} onSelect={() => {}} />);
    key(row("a"), "ArrowRight");
    expect($('li[data-value="a"]').getAttribute("aria-expanded")).toBe("true");
    key(row("a"), "ArrowRight");
    expect(focused()).toBe("a1");
    key(row("a1"), "ArrowLeft");
    expect(focused()).toBe("a");
    key(row("a"), "ArrowLeft");
    expect($('li[data-value="a"]').getAttribute("aria-expanded")).toBe("false");
  });

  it("picks with Enter, Space or a click, and leaves other keys to the browser", () => {
    const onSelect = vi.fn();
    render(<Tree label="Files" nodes={nodes} onSelect={onSelect} selected="b" />);
    expect($('li[data-value="b"]').getAttribute("aria-selected")).toBe("true");
    key(row("b"), "Enter");
    key(row("b"), " ");
    click(row("a"));
    expect(onSelect.mock.calls.map((c) => c[0])).toEqual(["b", "b", "a"]);
    expect(key(row("a"), "x")).toBe(false);
    expect(key(row("b"), "ArrowRight")).toBe(true); // a leaf: nothing to open, but the key is taken
  });

  it("opens and closes a branch with its toggle without picking the row", () => {
    const onSelect = vi.fn();
    render(<Tree defaultOpen={["a"]} label="Files" nodes={nodes} onSelect={onSelect} />);
    expect($('li[data-value="a"]').getAttribute("aria-expanded")).toBe("true");
    click($('li[data-value="a"] .kit-tree__toggle'));
    expect($('li[data-value="a"]').getAttribute("aria-expanded")).toBe("false");
    expect(onSelect).not.toHaveBeenCalled();
  });
});

describe("Menu", () => {
  const items = [{ value: "edit", label: "Edit" }, { value: "copy", label: "Copy" }, { value: "del", label: "Delete", danger: true, separatorBefore: true }];
  const open = () => click($(".kit-menu > .kit-btn"));
  const active = () => document.activeElement?.textContent;

  it("opens on its button with the first item focused, and the arrows move with wrap-around", () => {
    render(<Menu items={items} label="Actions" onPick={() => {}} />);
    expect($(".kit-menu__list").hidden).toBe(true);
    open();
    expect($(".kit-menu__list").hidden).toBe(false);
    expect($(".kit-menu > .kit-btn").getAttribute("aria-expanded")).toBe("true");
    expect(active()).toBe("Edit");
    key(document.activeElement!, "ArrowDown");
    expect(active()).toBe("Copy");
    key(document.activeElement!, "End");
    expect(active()).toBe("Delete");
    key(document.activeElement!, "ArrowDown");
    expect(active()).toBe("Edit");
    key(document.activeElement!, "ArrowUp");
    expect(active()).toBe("Delete");
    key(document.activeElement!, "Home");
    expect(active()).toBe("Edit");
    expect($$("hr.kit-menu__sep")).toHaveLength(1);
  });

  it("closes with Escape back on its button, with Tab without moving focus there, and on a click beside it", () => {
    render(<Menu items={items} label="Actions" onPick={() => {}} />);
    open();
    key(document.activeElement!, "Escape");
    expect($(".kit-menu__list").hidden).toBe(true);
    expect(document.activeElement).toBe($(".kit-menu > .kit-btn"));
    open();
    key(document.activeElement!, "Tab");
    expect($(".kit-menu__list").hidden).toBe(true);
    open();
    click(document.body);
    expect($(".kit-menu__list").hidden).toBe(true);
  });

  it("calls onPick with the item and closes", () => {
    const onPick = vi.fn();
    render(<Menu items={items} label="Actions" onPick={onPick} />);
    open();
    click($$(".kit-menu__item")[2]);
    expect(onPick).toHaveBeenCalledWith("del");
    expect($(".kit-menu__list").hidden).toBe(true);
  });
});

describe("Board", () => {
  const columns = [{ id: "todo", title: "To do" }, { id: "doing", title: "Doing" }, { id: "done", title: "Done" }];
  const cards: BoardCard[] = [
    { id: "a", column: "todo", content: "A" },
    { id: "b", column: "todo", content: "B" },
    { id: "c", column: "doing", content: "C" },
  ];
  const card = (id: string) => $(`[data-id="${id}"]`);

  it("moves a card with Alt and an arrow: up and down in its column, left and right to the end of the next", () => {
    const onMove = vi.fn();
    render(<Board cards={cards} columns={columns} onMove={onMove} />);
    expect(key(card("a"), "ArrowDown", { altKey: true })).toBe(true);
    expect(onMove).toHaveBeenLastCalledWith("a", "todo", 1);
    key(card("b"), "ArrowUp", { altKey: true });
    expect(onMove).toHaveBeenLastCalledWith("b", "todo", 0);
    key(card("a"), "ArrowRight", { altKey: true });
    expect(onMove).toHaveBeenLastCalledWith("a", "doing", 1);
    key(card("c"), "ArrowRight", { altKey: true });
    expect(onMove).toHaveBeenLastCalledWith("c", "done", 0);
    key(card("c"), "ArrowLeft", { altKey: true });
    expect(onMove).toHaveBeenLastCalledWith("c", "todo", 2);
    expect(onMove).toHaveBeenCalledTimes(5);
  });

  it("leaves a key alone at the board's edge or without Alt", () => {
    const onMove = vi.fn();
    render(<Board cards={cards} columns={columns} onMove={onMove} />);
    expect(key(card("a"), "ArrowUp", { altKey: true })).toBe(false);
    expect(key(card("a"), "ArrowLeft", { altKey: true })).toBe(false);
    expect(key(card("b"), "ArrowDown", { altKey: true })).toBe(false);
    expect(key(card("a"), "ArrowDown")).toBe(false);
    expect(onMove).not.toHaveBeenCalled();
  });

  it("drops a dragged card before the first card whose middle is below the pointer", () => {
    const onMove = vi.fn();
    render(<Board cards={cards} columns={columns} onMove={onMove} />);
    // Lay out the cards of To do: A at 0-40, B at 40-80.
    for (const [id, top] of [["a", 0], ["b", 40]] as const) {
      card(id).getBoundingClientRect = () => ({ top, bottom: top + 40, height: 40, left: 0, right: 100, width: 100, x: 0, y: top, toJSON: () => ({}) });
      Object.defineProperty(card(id), "offsetHeight", { value: 40 });
    }
    const dataTransfer = { setData: () => {}, effectAllowed: "" };
    const todo = $('[data-kit-board="todo"]');
    const drag = (id: string, list: HTMLElement, clientY: number) => {
      fire(card(id), "dragstart", { dataTransfer });
      fire(list, "dragover", { dataTransfer });
      fire(list, "drop", { dataTransfer, clientY });
    };
    drag("a", $('[data-kit-board="doing"]'), 0);
    expect(onMove).toHaveBeenLastCalledWith("a", "doing", 1); // C has no size here: after it
    drag("a", todo, 70); // among the others only B (middle 60): after it
    expect(onMove).toHaveBeenLastCalledWith("a", "todo", 1);
    drag("b", todo, 10); // A's middle (20) is below: before it
    expect(onMove).toHaveBeenLastCalledWith("b", "todo", 0);
  });

  it("ignores a drop that did not start as a card drag", () => {
    const onMove = vi.fn();
    render(<Board cards={cards} columns={columns} onMove={onMove} />);
    fire($('[data-kit-board="done"]'), "drop", { clientY: 0 });
    expect(onMove).not.toHaveBeenCalled();
  });
});

describe("Tabs", () => {
  it("moves with the arrows (wrapping), Home and End, one tab stop", () => {
    const onChange = vi.fn();
    render(<Tabs label="Views" onChange={onChange} tabs={["One", "Two", "Three"]} value={0} />);
    const list = $('[role="tablist"]');
    expect($$('[role="tab"]').map((t) => t.tabIndex)).toEqual([0, -1, -1]);
    expect($$('[role="tab"]')[0].getAttribute("aria-selected")).toBe("true");
    key(list, "ArrowRight");
    key(list, "ArrowLeft");
    key(list, "End");
    key(list, "Home");
    expect(onChange.mock.calls.map((c) => c[0])).toEqual([1, 2, 2, 0]);
    expect(key(list, "x")).toBe(false);
    click($$('[role="tab"]')[1]);
    expect(onChange).toHaveBeenLastCalledWith(1);
  });
});

describe("TagInput", () => {
  it("adds a tag with Enter or a comma, once, and removes with Backspace or its button", () => {
    const onChange = vi.fn();
    render(<TagInput label="Tags" onChange={onChange} value={["red"]} />);
    const input = $<HTMLInputElement>(".kit-tags__input");
    typeInto(input, " blue ");
    key(input, "Enter");
    expect(onChange).toHaveBeenLastCalledWith(["red", "blue"]);
    expect(input.value).toBe("");
    typeInto(input, "red");
    key(input, ",");
    expect(onChange).toHaveBeenCalledTimes(1); // a tag already there is not added again
    typeInto(input, "a,b");
    key(input, "Enter");
    expect(onChange).toHaveBeenLastCalledWith(["red", "a b"]);
    key(input, "Backspace");
    expect(onChange).toHaveBeenLastCalledWith([]);
    click($('[aria-label="Remove red"]'));
    expect(onChange).toHaveBeenLastCalledWith([]);
  });

  it("offers suggestions as a list only when there are some", () => {
    render(<TagInput label="Tags" onChange={() => {}} suggestions={["one", "two"]} value={[]} />);
    expect($$("datalist option")).toHaveLength(2);
    rerender(<TagInput label="Tags" onChange={() => {}} value={[]} />);
    expect($$("datalist")).toHaveLength(0);
  });
});

describe("Calendar", () => {
  it("lays out whole weeks from the week start, with the other months' days marked", () => {
    render(<Calendar events={[]} month="2024-02" weekStart={1} />);
    const days = $$(".kit-calendar__day");
    expect(days).toHaveLength(35); // 1 Feb 2024 is a Thursday: 3 days of January before it
    expect(days[0].getAttribute("data-date")).toBe("2024-01-29");
    expect(days[0].classList.contains("is-other")).toBe(true);
    expect(days[3].getAttribute("data-date")).toBe("2024-02-01");
    rerender(<Calendar events={[]} month="2024-02" weekStart={0} />);
    expect($$(".kit-calendar__day")[0].getAttribute("data-date")).toBe("2024-01-28");
  });

  it("shows up to three events a day, calls onDay with the day's events, and steps months across years", () => {
    const onDay = vi.fn();
    const onMonth = vi.fn();
    const events = [1, 2, 3, 4].map((n) => ({ date: "2024-12-14", title: "Item " + n }));
    render(<Calendar events={events} month="2024-12" onDay={onDay} onMonth={onMonth} />);
    const day = $('[data-date="2024-12-14"]');
    expect(day.querySelectorAll(".kit-calendar__event")).toHaveLength(4);
    expect(day.textContent).toContain("+1");
    expect(day.getAttribute("aria-label")).toContain("4 items");
    click(day);
    expect(onDay).toHaveBeenCalledWith("2024-12-14", events);
    click($('.kit-calendar__head [data-step="1"]'));
    click($('.kit-calendar__head [data-step="-1"]'));
    expect(onMonth.mock.calls.map((c) => c[0])).toEqual(["2025-01", "2024-11"]);
  });

  it("keeps the days as one tab stop and moves with the arrow, Home, End and Page keys", () => {
    const onMonth = vi.fn();
    const key = (el: Element, k: string, more: KeyboardEventInit = {}) => act(() => void el.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...more })));
    const stops = () => $$(".kit-calendar__day").filter((d) => d.getAttribute("tabindex") === "0").map((d) => d.getAttribute("data-date"));
    render(<Calendar events={[]} month="2024-03" onMonth={onMonth} weekStart={1} />);
    expect(stops()).toEqual(["2024-03-01"]); // not this month: the 1st takes the Tab key
    act(() => ($('[data-date="2024-03-31"]') as HTMLElement).focus());
    expect(stops()).toEqual(["2024-03-31"]);
    key($('[data-date="2024-03-31"]'), "ArrowLeft");
    expect(document.activeElement?.getAttribute("data-date")).toBe("2024-03-30");
    key($('[data-date="2024-03-30"]'), "Home");
    expect(document.activeElement?.getAttribute("data-date")).toBe("2024-03-25"); // the Monday of that week
    key($('[data-date="2024-03-25"]'), "End");
    expect(document.activeElement?.getAttribute("data-date")).toBe("2024-03-31");
    key($('[data-date="2024-03-31"]'), "PageDown"); // 31 March -> 30 April: the page is asked for April
    expect(onMonth).toHaveBeenLastCalledWith("2024-04");
    rerender(<Calendar events={[]} month="2024-04" onMonth={onMonth} weekStart={1} />);
    expect(document.activeElement?.getAttribute("data-date")).toBe("2024-04-30");
    expect(stops()).toEqual(["2024-04-30"]);
    key($('[data-date="2024-04-30"]'), "PageUp", { shiftKey: true });
    expect(onMonth).toHaveBeenLastCalledWith("2023-04");
    click($(".kit-calendar__head [data-today]"));
    expect(onMonth).toHaveBeenLastCalledWith(new Date().toISOString().slice(0, 4) + "-" + ("0" + (new Date().getMonth() + 1)).slice(-2));
  });

  it("takes the week start from the kit's setting when the page gives none", () => {
    document.documentElement.style.setProperty("--kit-week-start", "0");
    render(<Calendar events={[]} month="2024-02" />);
    expect($$(".kit-calendar__day")[0].getAttribute("data-date")).toBe("2024-01-28");
    document.documentElement.style.removeProperty("--kit-week-start");
  });
});

describe("HoldButton", () => {
  it("confirms only after being held for the whole time", () => {
    vi.useFakeTimers();
    const onConfirm = vi.fn();
    render(<HoldButton holdMs={1000} label="Delete" onConfirm={onConfirm} />);
    const b = $("button");
    key(b, "Enter");
    expect(b.textContent).toBe("Keep holding...");
    act(() => vi.advanceTimersByTime(500));
    act(() => {
      b.dispatchEvent(new KeyboardEvent("keyup", { key: "Enter", bubbles: true }));
    });
    act(() => vi.advanceTimersByTime(1000));
    expect(onConfirm).not.toHaveBeenCalled();
    expect(b.textContent).toBe("Delete");
    key(b, " ");
    act(() => vi.advanceTimersByTime(1000));
    expect(onConfirm).toHaveBeenCalledTimes(1);
    expect(b.classList.contains("is-done")).toBe(true);
  });

  it("does nothing while disabled", () => {
    vi.useFakeTimers();
    const onConfirm = vi.fn();
    render(<HoldButton disabled holdMs={100} label="Delete" onConfirm={onConfirm} />);
    key($("button"), "Enter");
    act(() => vi.advanceTimersByTime(200));
    expect(onConfirm).not.toHaveBeenCalled();
  });
});

describe("Drawer", () => {
  it("opens and closes with its prop, and asks to close from its button, the backdrop and Escape", () => {
    const onClose = vi.fn();
    render(
      <Drawer onClose={onClose} open title="Details">
        <p>Body</p>
      </Drawer>,
    );
    const d = $<HTMLDialogElement>("dialog.kit-drawer");
    expect(d.open).toBe(true);
    expect(d.getAttribute("aria-labelledby")).toBe($(".kit-drawer__title").id);
    click($(".kit-drawer__head button"));
    click(d); // a click on the dialog itself is the backdrop
    click($(".kit-drawer__body p")); // inside the panel: not the backdrop
    const cancel = fire(d, "cancel");
    expect(cancel.defaultPrevented).toBe(true);
    expect(onClose).toHaveBeenCalledTimes(3);
    rerender(
      <Drawer onClose={onClose} open={false} title="Details">
        <p>Body</p>
      </Drawer>,
    );
    expect(d.open).toBe(false);
  });
});

describe("Popover", () => {
  it("opens with the first field focused, and closes with Escape (back on its button) or a click beside it", () => {
    render(
      <Popover label="Columns">
        <label>
          <input type="checkbox" /> Name
        </label>
      </Popover>,
    );
    const button = $(".kit-popover-wrap > button");
    const panel = $(".kit-popover");
    expect(panel.hidden).toBe(true);
    click(button);
    expect(panel.hidden).toBe(false);
    expect(button.getAttribute("aria-controls")).toBe(panel.id);
    expect(document.activeElement).toBe($('.kit-popover input'));
    key(document.activeElement!, "Escape");
    expect(panel.hidden).toBe(true);
    expect(document.activeElement).toBe(button);
    click(button);
    click(document.body);
    expect(panel.hidden).toBe(true);
  });
});

describe("useConfirm", () => {
  let api: ReturnType<typeof useConfirm> | null = null;
  function Harness() {
    const c = useConfirm();
    useEffect(() => {
      api = c;
    });
    return <>{c.box}</>;
  }
  beforeAll(() => {
    api = null;
  });

  it("answers true for OK, false for Cancel and Escape, and shows queued questions one after another", async () => {
    render(<Harness />);
    let first: Promise<boolean> | undefined;
    let second: Promise<boolean> | undefined;
    act(() => {
      first = api!.confirm("Delete 3 items?", { title: "Delete items", ok: "Delete", danger: true });
      second = api!.confirm("Really?");
    });
    expect($("dialog.kit-dialog h3").textContent).toBe("Delete items");
    expect(document.activeElement).toBe($("dialog.kit-dialog [data-cancel]")); // with danger, Cancel has the focus
    expect($("dialog.kit-dialog").getAttribute("aria-labelledby")).toBe($("dialog.kit-dialog h3").id);
    expect($("dialog.kit-dialog").getAttribute("aria-describedby")).toBe($("dialog.kit-dialog p").id);
    click($(".kit-btn--danger"));
    await expect(first).resolves.toBe(true);
    expect($("dialog.kit-dialog p").textContent).toBe("Really?");
    fire($("dialog.kit-dialog"), "cancel");
    await expect(second).resolves.toBe(false);
    expect($$("dialog.kit-dialog")).toHaveLength(0);
  });

  it("shows an alert with only its OK button", async () => {
    render(<Harness />);
    let done: Promise<void> | undefined;
    act(() => {
      done = api!.alert("The export is ready.");
    });
    expect($$("dialog.kit-dialog button")).toHaveLength(1);
    click($(".kit-btn--primary"));
    await expect(done).resolves.toBeUndefined();
  });
});

describe("Chart", () => {
  it("draws again only when the data itself changed, and passes picks to onSelect", async () => {
    const bar = vi.fn();
    // kit-charts.js leaves an existing KitCharts alone (loaded twice), so this stands in for it.
    (window as unknown as { KitCharts: unknown }).KitCharts = { bar };
    const { Chart } = await import("../../templates/ui-kit/react/Chart");
    const onSelect = vi.fn();
    render(<Chart data={{ labels: ["a"], series: [{ name: "x", values: [1] }] }} kind="bar" label="Sales" onSelect={onSelect} />);
    expect(bar).toHaveBeenCalledTimes(1);
    rerender(<Chart data={{ labels: ["a"], series: [{ name: "x", values: [1] }] }} kind="bar" label="Sales" onSelect={onSelect} />);
    expect(bar).toHaveBeenCalledTimes(1);
    rerender(<Chart data={{ labels: ["a"], series: [{ name: "x", values: [2] }] }} kind="bar" label="Sales" onSelect={onSelect} />);
    expect(bar).toHaveBeenCalledTimes(2);
    const pick = { chart: "bar", part: "bar", value: "a", index: 0 };
    act(() => {
      $(".kit-chart").dispatchEvent(new CustomEvent("kit:select", { detail: pick }));
    });
    expect(onSelect).toHaveBeenCalledWith(pick);
    expect($(".kit-chart").getAttribute("aria-label")).toBe("Sales");
  });
});

describe("Tooltip", () => {
  it("shows at once on keyboard focus, after a rest on hover, describes only when it adds words, and hides on Escape", () => {
    vi.useFakeTimers({ now: Date.now() + 60000 });
    render(
      <div>
        <Tooltip text="Edit">
          <button aria-label="Edit" type="button" />
        </Tooltip>
        <Tooltip text="Download the table (Ctrl+S)">
          <button aria-label="Download" id="dl" type="button" />
        </Tooltip>
      </div>,
    );
    const [edit, dl] = $$("button");
    act(() => edit.focus());
    expect($(".kit-tooltip").textContent).toBe("Edit");
    expect($(".kit-tooltip").getAttribute("role")).toBe("tooltip");
    expect(edit.getAttribute("aria-describedby")).toBeNull(); // the same words as its name
    expect(key(edit, "Escape")).toBe(true);
    expect(document.querySelector(".kit-tooltip")).toBeNull();
    act(() => edit.blur());
    act(() => vi.advanceTimersByTime(1000));
    act(() => {
      dl.dispatchEvent(new MouseEvent("mouseover", { bubbles: true, relatedTarget: document.body }));
    });
    act(() => vi.advanceTimersByTime(499));
    expect(document.querySelector(".kit-tooltip")).toBeNull();
    act(() => vi.advanceTimersByTime(1));
    expect($(".kit-tooltip").textContent).toBe("Download the table (Ctrl+S)");
    expect(dl.getAttribute("aria-describedby")).toBe($(".kit-tooltip").id);
    act(() => {
      dl.dispatchEvent(new MouseEvent("mouseout", { bubbles: true, relatedTarget: document.body }));
    });
    expect(document.querySelector(".kit-tooltip")).toBeNull();
  });
});

describe("Toaster", () => {
  it("gives a toast a Dismiss button and keeps it while the pointer is on it", () => {
    vi.useFakeTimers();
    render(<Toaster />);
    act(() => {
      toast("Saved");
    });
    const t = $(".kit-toast");
    const x = $<HTMLButtonElement>(".kit-toast__close");
    expect(x.getAttribute("aria-label")).toBe("Dismiss");
    expect(x.className).toBe("kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm kit-toast__close");
    act(() => {
      t.dispatchEvent(new MouseEvent("mouseover", { bubbles: true, relatedTarget: document.body }));
    });
    act(() => vi.advanceTimersByTime(20000));
    expect(t.classList.contains("is-leaving")).toBe(false);
    act(() => {
      t.dispatchEvent(new MouseEvent("mouseout", { bubbles: true, relatedTarget: document.body }));
    });
    act(() => vi.advanceTimersByTime(4100));
    expect($(".kit-toast").classList.contains("is-leaving")).toBe(true);
    act(() => vi.advanceTimersByTime(400));
    expect(document.querySelector(".kit-toast")).toBeNull();
    act(() => {
      toast("Plain", { close: false });
      toast("Sent");
    });
    expect($$(".kit-toast__close")).toHaveLength(1);
    click($(".kit-toast__close"));
    expect($$(".kit-toast")[1].classList.contains("is-leaving")).toBe(true);
    act(() => vi.advanceTimersByTime(10000));
  });
});

describe("Menu as a context menu", () => {
  function Row({ onPick }: { onPick: (v: string) => void }) {
    const row = useRef<HTMLLIElement>(null);
    return (
      <ul>
        <li ref={row}>
          <span id="name">Report</span>
          <Menu buttonLabel="Actions for Report" contextRef={row} items={[{ value: "open", label: "Open" }, { value: "del", label: "Delete", danger: true, separatorBefore: true }]} label="..." onPick={onPick} />
        </li>
      </ul>
    );
  }
  it("opens the same list at the pointer on a right click and Shift+F10, with an icon button as the visible way", () => {
    const onPick = vi.fn();
    render(<Row onPick={onPick} />);
    const button = $(".kit-menu > button");
    expect(button.className).toBe("kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm");
    expect(button.getAttribute("aria-label")).toBe("Actions for Report");
    const right = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 120, clientY: 40 });
    act(() => {
      $("#name").dispatchEvent(right);
    });
    expect(right.defaultPrevented).toBe(true);
    const list = $(".kit-menu__list");
    expect(list.hidden).toBe(false);
    expect([list.style.position, list.style.left, list.style.top]).toEqual(["fixed", "120px", "40px"]);
    expect(document.activeElement!.textContent).toBe("Open");
    key(document.activeElement!, "Escape");
    expect(list.hidden).toBe(true);
    act(() => button.focus());
    expect(key(button, "F10", { shiftKey: true })).toBe(true);
    expect(list.hidden).toBe(false);
    click($$(".kit-menu__item")[1]);
    expect(onPick).toHaveBeenCalledWith("del");
    expect(document.activeElement).toBe(button);
    click(button);
    expect(list.style.position).toBe(""); // its own button opens it in its own place
  });
});

describe("CommandPalette", () => {
  const commands = [
    { value: "new", label: "New station", shortcut: "N" },
    { value: "print", label: "Print this page" },
  ];
  it("opens with Ctrl+K but not from a field, filters, runs with Enter and clears the text before it closes", () => {
    const onRun = vi.fn();
    render(
      <div>
        <input aria-label="Name" id="field" />
        <button id="start" type="button">
          Start
        </button>
        <CommandPalette commands={commands} onRun={onRun} />
      </div>,
    );
    const d = $<HTMLDialogElement>("dialog.kit-palette");
    expect(d.className).toBe("kit-dialog kit-palette");
    expect(key($("#field"), "k", { ctrlKey: true })).toBe(false);
    expect(d.hasAttribute("open")).toBe(false);
    act(() => $("#start").focus());
    expect(key($("#start"), "k", { ctrlKey: true })).toBe(true);
    expect(d.hasAttribute("open")).toBe(true);
    const input = $<HTMLInputElement>("dialog input");
    expect(document.activeElement).toBe(input);
    expect(input.getAttribute("role")).toBe("combobox");
    expect(input.getAttribute("aria-activedescendant")).toBe($$(".kit-search__item")[0].id);
    expect($(".kit-kbd").textContent).toBe("N");
    typeInto(input, "print");
    expect($$(".kit-search__item").map((r) => r.textContent)).toEqual(["Print this page"]);
    expect(key(input, "Escape")).toBe(true); // the text first
    expect(input.value).toBe("");
    expect(d.hasAttribute("open")).toBe(true);
    typeInto(input, "zzz");
    expect($(".kit-empty").hidden).toBe(false);
    typeInto(input, "new");
    key(input, "Enter");
    expect(onRun).toHaveBeenCalledWith(commands[0]);
    expect(d.hasAttribute("open")).toBe(false);
    expect(document.activeElement).toBe($("#start"));
  });
});

describe("ThemeToggle", () => {
  it("switches data-theme on html, keeps the choice and says what a click does", () => {
    document.documentElement.removeAttribute("data-theme");
    render(<ThemeToggle />);
    const b = $<HTMLButtonElement>("button.kit-btn--icon");
    expect(b.getAttribute("aria-label")).toBe("Switch to the dark theme");
    expect($("[data-icon]").getAttribute("data-icon")).toBe("moon");
    const seen = vi.fn();
    document.addEventListener("kit:theme", seen, { once: true });
    click(b);
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    expect(localStorage.getItem("kit-theme")).toBe("dark");
    expect(b.getAttribute("aria-label")).toBe("Switch to the light theme");
    expect($("[data-icon]").getAttribute("data-icon")).toBe("sun");
    expect(seen).toHaveBeenCalledTimes(1);
    document.documentElement.removeAttribute("data-theme");
    localStorage.removeItem("kit-theme");
  });
});

describe("AppShell", () => {
  it("draws the kit-shell with the band header, opens the navigation from its menu button and closes it with a link or Escape", () => {
    render(
      <AppShell links={[{ href: "#a", label: "Overview", current: true }, { href: "#b", label: "Items" }]} title="Example app">
        <h1>Overview</h1>
      </AppShell>,
    );
    expect($(".kit-shell > .kit-header.kit-header--band .kit-header__title").textContent).toBe("Example app");
    const menu = $<HTMLButtonElement>(".kit-shell__menu");
    const nav = $(".kit-shell__nav");
    expect(menu.getAttribute("aria-controls")).toBe(nav.id);
    expect($(".kit-nav__item").getAttribute("aria-current")).toBe("page");
    expect($("main.kit-shell__main").id).toBe("main");
    expect($(".kit-skip").getAttribute("href")).toBe("#main");
    click(menu);
    expect(nav.classList.contains("is-open")).toBe(true);
    expect(menu.getAttribute("aria-expanded")).toBe("true");
    click($$(".kit-nav__item")[1]);
    expect(nav.classList.contains("is-open")).toBe(false);
    click(menu);
    key(document.body, "Escape");
    expect(nav.classList.contains("is-open")).toBe(false);
    expect(document.activeElement).toBe(menu);
  });
});
