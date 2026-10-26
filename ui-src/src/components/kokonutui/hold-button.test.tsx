// @vitest-environment jsdom
// The hold-to-confirm button (run approvals, setup, tidy-up, SharePoint publish): what holding,
// releasing early and a disabled button do. The fill animation is stood in for, so a test decides
// when it ends; the rules themselves are tested in lib/viewer-search-hold.test.ts.
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const anim = vi.hoisted(() => ({ finish: null as null | (() => void), starts: 0, stops: 0 }));

vi.mock("motion/react", () => ({
  motion: { div: (p: { className?: string }) => <div className={p.className} data-fill="" /> },
  useAnimation: () => ({
    set: () => {},
    stop: () => {
      anim.stops++;
    },
    start: (to: { width: string }) => {
      anim.starts++;
      // The grow animation ends when the test says so; the shrink after a release ends at once.
      if (to.width !== "100%") return Promise.resolve();
      return new Promise<void>((resolve) => {
        anim.finish = resolve;
      });
    },
  }),
}));

import HoldButton from "./hold-button";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let root: Root | null = null;
let host: HTMLDivElement | null = null;

function render(ui: ReactNode) {
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  act(() => root!.render(ui));
  return host.querySelector("button")!;
}
const press = (b: HTMLButtonElement, type: string) => act(() => void b.dispatchEvent(new MouseEvent(type, { bubbles: true })));
const endAnimation = async (ms: number) => {
  vi.advanceTimersByTime(ms);
  await act(async () => anim.finish?.());
};

beforeEach(() => {
  vi.useFakeTimers();
  anim.finish = null;
  anim.starts = 0;
  anim.stops = 0;
});
afterEach(() => {
  act(() => root?.unmount());
  host?.remove();
  root = null;
  host = null;
  vi.useRealTimers();
});

describe("HoldButton", () => {
  it("shows its label, the variant's look and icon, or the icon it is given", () => {
    const html = renderToStaticMarkup(<HoldButton label="Hold to run" variant="grey" />);
    expect(html).toContain("Hold to run");
    expect(html).toContain("bg-black/5");
    expect(html).toContain("bg-black/10");
    expect(html).toContain("lucide-ban");
    const own = renderToStaticMarkup(<HoldButton icon={<i data-own="" />} />);
    expect(own).toContain("data-own");
    expect(own).not.toContain("lucide-trash");
    expect(own).toContain("Hold me");
  });

  it("fires once it was held the whole time, saying Release while held", async () => {
    const done = vi.fn();
    const b = render(<HoldButton holdDuration={1200} holdingLabel="Keep holding" label="Hold" onHoldComplete={done} />);
    press(b, "mousedown");
    expect(b.textContent).toBe("Keep holding");
    await endAnimation(1200);
    expect(done).toHaveBeenCalledTimes(1);
    expect(b.textContent).toBe("Hold");
  });

  it("does not fire when released early, and shrinks the fill again", async () => {
    const done = vi.fn();
    const b = render(<HoldButton holdDuration={1200} label="Hold" onHoldComplete={done} />);
    press(b, "mousedown");
    vi.advanceTimersByTime(400);
    press(b, "mouseup");
    expect(anim.stops).toBe(1);
    expect(b.textContent).toBe("Hold");
    await endAnimation(0);
    expect(done).not.toHaveBeenCalled();
  });

  it("does not fire when the pointer leaves before the end", async () => {
    const done = vi.fn();
    const b = render(<HoldButton holdDuration={1200} onHoldComplete={done} />);
    press(b, "mousedown");
    press(b, "mouseout");
    vi.advanceTimersByTime(1200);
    await act(async () => anim.finish?.());
    expect(done).not.toHaveBeenCalled();
  });

  it("does nothing while disabled", async () => {
    const done = vi.fn();
    const b = render(<HoldButton disabled label="Hold" onHoldComplete={done} />);
    press(b, "mousedown");
    expect(anim.starts).toBe(0);
    expect(b.textContent).toBe("Hold");
    expect(done).not.toHaveBeenCalled();
  });
});
