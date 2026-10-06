import { describe, expect, it } from "vitest";
import { followBottom, isNearBottom } from "./stick-to-bottom";

/** A scroll area: its content height, the visible height and the scroll position. */
function fakeScroller(scrollHeight: number, clientHeight: number, scrollTop: number) {
  let onScroll: () => void = () => {};
  const el = {
    scrollHeight,
    clientHeight,
    _top: scrollTop,
    get scrollTop() { return this._top; },
    set scrollTop(v: number) { this._top = Math.max(0, Math.min(v, this.scrollHeight - this.clientHeight)); },
    addEventListener: (_: string, f: () => void) => { onScroll = f; },
    removeEventListener: () => {},
  };
  return { el, scroll: (top: number) => { el.scrollTop = top; onScroll(); } };
}

class FakeResizeObserver {
  static last: FakeResizeObserver | null = null;
  cb: () => void;
  constructor(cb: () => void) { this.cb = cb; FakeResizeObserver.last = this; }
  observe() {}
  disconnect() {}
}

describe("isNearBottom", () => {
  it("counts the last 80 px as the bottom", () => {
    expect(isNearBottom(1000, 500, 500)).toBe(true);
    expect(isNearBottom(1000, 430, 500)).toBe(true);
    expect(isNearBottom(1000, 400, 500)).toBe(false);
  });
});

describe("followBottom", () => {
  const g = globalThis as Record<string, unknown>;
  it("follows growing content while the reader is at the bottom, not after they scroll up, and again after stick()", () => {
    g.ResizeObserver = FakeResizeObserver;
    try {
      const s = fakeScroller(1000, 500, 500);
      const f = followBottom(s.el as unknown as HTMLElement, {} as HTMLElement);
      const grow = (h: number) => { s.el.scrollHeight = h; FakeResizeObserver.last!.cb(); };
      grow(1400);                       // a reply streams in
      expect(s.el.scrollTop).toBe(900);
      s.scroll(300);                    // the reader scrolls up to read
      grow(1800);
      expect(s.el.scrollTop).toBe(300); // left where they read
      s.scroll(1300);                   // back down to the bottom
      grow(2000);
      expect(s.el.scrollTop).toBe(1500);
      s.scroll(100);
      f.stick();                        // they send a message
      expect(s.el.scrollTop).toBe(1500);
      f.stop();
    } finally {
      delete g.ResizeObserver;
    }
  });
});
