// @vitest-environment jsdom
// The side panel (components/ccb/side-panel.tsx) as a person uses it, with invented data and the
// server's API answering nothing: the Files tab lists the project as a tree and opens a file; the
// History tab explains itself when empty, lists change sets newest first, opens a file on the
// lines a change set changed, undoes the latest, and restores an older one only after a yes.
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

// The server is out of reach: every API call stays pending (the panel shows its own data only).
vi.mock("@/lib/api", async (importOriginal) => {
  const real = await importOriginal<typeof import("@/lib/api")>();
  return { ...real, api: new Proxy({}, { get: () => () => new Promise(() => {}) }) };
});

import { writeStored } from "@/lib/stored";
import type { ChangeSetView, FileInfo } from "@/lib/api";
import { SidePanel } from "./side-panel";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

beforeAll(() => {
  // jsdom has no layout observers; the tabs measure their labels with one.
  (globalThis as { ResizeObserver?: unknown }).ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
});

let root: Root | null = null;
let host: HTMLDivElement | null = null;

type Props = Parameters<typeof SidePanel>[0];
function props(over: Partial<Props> = {}): Props {
  return {
    reviewTick: 0, schedules: [], onSchedule: () => {}, files: [], todos: [], changes: [], onOpenFile: () => {}, onUndo: () => {},
    onUploaded: () => {}, busy: false, fetchItems: [], onRunFetch: () => {}, onSaveFetch: async () => {}, onAttach: () => {},
    project: { name: "Budget tracker", path: "C:/demo/Budget tracker" }, runbooks: [], runbookTemplates: [], onCreateRunbook: async () => {},
    onRunRunbook: () => {}, queue: [], ...over,
  };
}
function render(p: Props, tab: "files" | "changes") {
  writeStored("ccb.sideTab", tab);   // the side panel opens on the tab it was last on
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  act(() => root!.render(<SidePanel {...p} />));
  return host;
}
const buttons = (box: HTMLElement) => Array.from(box.querySelectorAll("button"));
const buttonWithText = (box: HTMLElement, text: string) => buttons(box).find((b) => b.textContent?.trim() === text);
const click = (el: Element | undefined) => {
  expect(el, "the control to click").toBeTruthy();
  act(() => void el!.dispatchEvent(new MouseEvent("click", { bubbles: true })));
};

beforeEach(() => localStorage.clear());
afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
  root = null;
  host = null;
});

describe("SidePanel: Files", () => {
  const files: FileInfo[] = [
    { path: "index.html", size: 120 },
    { path: "data/sales.csv", size: 64 },
  ];

  it("lists the project's files as a tree, folders before files, and opens a file", () => {
    const onOpenFile = vi.fn();
    const box = render(props({ files, onOpenFile }), "files");

    const rows = buttons(box).map((b) => b.title).filter((t) => /^(data|index\.html|data\/sales\.csv)\b/.test(t));
    expect(rows.slice(0, 3).map((t) => t.split(" ")[0])).toEqual(["data", "data/sales.csv", "index.html"]);
    click(buttons(box).find((b) => b.title.startsWith("data/sales.csv ")));
    expect(onOpenFile).toHaveBeenCalledWith("data/sales.csv");
  });

  it("folds a folder away and opens it again", () => {
    const box = render(props({ files }), "files");
    const folder = buttons(box).find((b) => b.title === "data")!;

    click(folder);
    expect(folder.getAttribute("aria-expanded")).toBe("false");
    expect(buttons(box).some((b) => b.title.startsWith("data/sales.csv "))).toBe(false);
    click(folder);
    expect(buttons(box).some((b) => b.title.startsWith("data/sales.csv "))).toBe(true);
  });
});

describe("SidePanel: History", () => {
  const changes: ChangeSetView[] = [
    { seq: 1, time: "10:02", title: "Add a sales table", files: ["index.html"], changeSet: "cs-1" },
    { seq: 2, time: "10:15", title: "Add a total row", files: ["app.js"], changeSet: "cs-2", counts: [{ path: "app.js", added: 4, removed: 1 }] },
  ];

  it("says what it holds while it is empty, and Undo has nothing to take back", () => {
    const box = render(props(), "changes");

    expect(box.textContent).toContain("Files changed in this session are listed here.");
    const undo = buttons(box).find((b) => b.textContent?.includes("Undo last change set"));
    expect(undo?.disabled).toBe(true);
  });

  it("lists change sets newest first, marks the latest, opens a file on its changed lines, and undoes", () => {
    const onOpenChangeFile = vi.fn();
    const onUndo = vi.fn();
    const box = render(props({ changes, onOpenChangeFile, onUndo }), "changes");

    const titles = Array.from(box.querySelectorAll("[id^='change-']")).map((c) => c.id);
    expect(titles).toEqual(["change-2", "change-1"]);
    expect(box.querySelector("#change-2")!.textContent).toContain("latest: Undo takes this back");
    expect(box.querySelector("#change-1")!.textContent).not.toContain("latest");

    click(buttons(box.querySelector("#change-2") as HTMLElement).find((b) => b.title.startsWith("app.js: the lines this change set")));
    expect(onOpenChangeFile).toHaveBeenCalledWith("cs-2", "app.js");

    click(buttons(box).find((b) => b.textContent?.includes("Undo last change set")));
    expect(onUndo).toHaveBeenCalledTimes(1);
  });

  it("undoes to an older change set only after a yes, undoing it and every newer one", () => {
    const onUndoTo = vi.fn();
    const box = render(props({ changes, onUndoTo }), "changes");
    const older = box.querySelector("#change-1") as HTMLElement;

    click(buttonWithText(older, "Undo to here"));
    expect(older.textContent).toContain("Undo 2 change sets?");
    expect(onUndoTo).not.toHaveBeenCalled();
    click(buttonWithText(box.querySelector("#change-1") as HTMLElement, "Yes"));
    expect(onUndoTo).toHaveBeenCalledWith("cs-1");
  });
});
