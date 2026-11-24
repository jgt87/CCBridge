// @vitest-environment jsdom
// The app's modal layer (settings, schedules, command palette, file viewer): a labelled modal dialog
// that takes focus, keeps Tab inside, makes the page behind inert and gives focus back on close.
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ModalBackdrop } from "./modal-backdrop";
import { ConfirmRemove } from "./confirm-remove";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let root: Root | null = null;
let page: HTMLDivElement;
let opener: HTMLButtonElement;

beforeEach(() => {
  // jsdom lays nothing out: every element counts as shown.
  vi.spyOn(Element.prototype, "getClientRects").mockReturnValue([{}] as unknown as DOMRectList);
  page = document.createElement("div");
  opener = document.createElement("button");
  opener.textContent = "Open";
  page.appendChild(opener);
  document.body.appendChild(page);
  opener.focus();
  root = createRoot(page.appendChild(document.createElement("div")));
});
afterEach(() => {
  act(() => root?.unmount());
  page.remove();
  vi.restoreAllMocks();
});

const tab = (shiftKey = false) =>
  act(() => void document.activeElement!.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Tab", shiftKey })));

describe("ModalBackdrop", () => {
  it("is a labelled modal dialog that takes focus and makes the page behind inert", () => {
    act(() =>
      root!.render(
        <ModalBackdrop label="Settings" onClose={() => {}}>
          <div className="kit-dialog">
            <button type="button">Close</button>
            <input aria-label="Name" />
          </div>
        </ModalBackdrop>
      )
    );
    const dialog = document.querySelector('[role="dialog"]')!;
    expect(dialog.className).toBe("kit-dialog");
    expect(dialog.getAttribute("aria-modal")).toBe("true");
    expect(dialog.getAttribute("aria-label")).toBe("Settings");
    expect(document.activeElement?.getAttribute("aria-label")).toBe("Name");
    expect(page.inert).toBe(true);
  });

  it("is named by its visible title when it has one", () => {
    act(() =>
      root!.render(
        <ModalBackdrop label="Scheduled" onClose={() => {}} titleId="sched-title">
          <div className="kit-dialog">
            <div id="sched-title">Scheduled</div>
            <button type="button">Close</button>
          </div>
        </ModalBackdrop>
      )
    );
    const dialog = document.querySelector('[role="dialog"]')!;
    expect(dialog.getAttribute("aria-labelledby")).toBe("sched-title");
    expect(dialog.hasAttribute("aria-label")).toBe(false);
    expect(document.getElementById("sched-title")?.textContent).toBe("Scheduled");
  });

  it("keeps Tab inside and gives focus back on close", () => {
    act(() =>
      root!.render(
        <ModalBackdrop label="Viewer" onClose={() => {}}>
          <div className="kit-dialog">
            <button type="button">First</button>
            <button type="button">Last</button>
          </div>
        </ModalBackdrop>
      )
    );
    expect(document.activeElement?.textContent).toBe("First");
    tab(true);
    expect(document.activeElement?.textContent).toBe("Last");
    tab();
    expect(document.activeElement?.textContent).toBe("First");
    act(() => root!.render(null));
    expect(page.inert).toBe(false);
    expect(document.activeElement).toBe(opener);
  });

  it("closes on a press beside the content only", () => {
    const close = vi.fn();
    act(() =>
      root!.render(
        <ModalBackdrop label="Menu" onClose={close}>
          <div className="kit-dialog">
            <button type="button">Inside</button>
          </div>
        </ModalBackdrop>
      )
    );
    act(() => void document.querySelector('[role="dialog"] button')!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true })));
    expect(close).not.toHaveBeenCalled();
    act(() => void document.querySelector('[role="dialog"]')!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true })));
    expect(close).not.toHaveBeenCalled();
    act(() => void document.querySelector('[role="dialog"]')!.parentElement!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true })));
    expect(close).toHaveBeenCalledTimes(1);
  });
});

describe("ConfirmRemove", () => {
  it("asks once more before removing, with focus on Cancel", () => {
    const remove = vi.fn();
    act(() => root!.render(<ConfirmRemove name="sales" onRemove={remove} />));
    const first = page.querySelector<HTMLButtonElement>('button[aria-label="Remove sales"]')!;
    act(() => first.click());
    expect(remove).not.toHaveBeenCalled();
    expect(page.textContent).toContain("Remove sales?");
    expect(document.activeElement?.textContent).toBe("Cancel");
    act(() => (document.activeElement as HTMLButtonElement).click());
    expect(page.textContent).not.toContain("Remove sales?");
    act(() => page.querySelector<HTMLButtonElement>('button[aria-label="Remove sales"]')!.click());
    const yes = Array.from(page.querySelectorAll("button")).find((b) => b.textContent === "Remove" && !b.getAttribute("aria-label"))!;
    act(() => yes.click());
    expect(remove).toHaveBeenCalledTimes(1);
  });
});
