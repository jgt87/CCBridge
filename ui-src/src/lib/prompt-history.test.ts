import { describe, expect, it } from "vitest";
import { historyStep, historyText, isPlainArrow, isSendKey } from "./prompt-history";

const key = (k: string, mods: Partial<Record<"shiftKey" | "altKey" | "ctrlKey" | "metaKey", boolean>> = {}) => ({
  key: k,
  shiftKey: false,
  altKey: false,
  ctrlKey: false,
  metaKey: false,
  ...mods,
});
const box = (value: string, start: number, end = start) => ({ value, selectionStart: start, selectionEnd: end });

describe("message history in the message box", () => {
  it("only takes arrow keys pressed on their own", () => {
    expect(isPlainArrow(key("ArrowUp"))).toBe(true);
    expect(isPlainArrow(key("ArrowDown"))).toBe(true);
    expect(isPlainArrow(key("ArrowLeft"))).toBe(false);
    expect(isPlainArrow(key("ArrowUp", { shiftKey: true }))).toBe(false);
    expect(isPlainArrow(key("ArrowDown", { ctrlKey: true }))).toBe(false);
  });

  it("goes up from the first line while older messages remain, down from the last line while browsing", () => {
    expect(historyStep("ArrowUp", box("hello", 3), -1, 2)).toBe(0);
    expect(historyStep("ArrowUp", box("hello", 3), 0, 2)).toBe(1);
    expect(historyStep("ArrowUp", box("hello", 3), 1, 2)).toBeNull();
    expect(historyStep("ArrowDown", box("hello", 3), 1, 2)).toBe(0);
    expect(historyStep("ArrowDown", box("hello", 3), 0, 2)).toBe(-1);
    expect(historyStep("ArrowDown", box("hello", 3), -1, 2)).toBeNull();
  });

  it("leaves the arrows to the cursor inside a message of several lines", () => {
    expect(historyStep("ArrowUp", box("one\ntwo", 5), -1, 2)).toBeNull();
    expect(historyStep("ArrowDown", box("one\ntwo", 1), 0, 2)).toBeNull();
    expect(historyStep("ArrowUp", box("one\ntwo", 2), -1, 2)).toBe(0);
  });

  it("gives the kept draft at -1 and the newest earlier message at 0", () => {
    const history = ["oldest", "middle", "newest"];
    expect(historyText(history, -1, "typing")).toBe("typing");
    expect(historyText(history, 0, "typing")).toBe("newest");
    expect(historyText(history, 2, "typing")).toBe("oldest");
  });
});

describe("sending with Enter", () => {
  it("sends on Enter alone, not with Shift and not while an input method composes text", () => {
    expect(isSendKey({ key: "Enter", shiftKey: false })).toBe(true);
    expect(isSendKey({ key: "Enter", shiftKey: true })).toBe(false);
    // Confirming a Japanese or Chinese conversion with Enter must not send the message.
    expect(isSendKey({ key: "Enter", shiftKey: false, composing: true })).toBe(false);
    expect(isSendKey({ key: "a", shiftKey: false })).toBe(false);
  });
});

describe("a history that shrank while browsing it", () => {
  it("steps from the oldest message still there and never gives undefined text", () => {
    const history = ["only"];
    // Browsing at position 2 when there were three messages; after a restart one is left.
    expect(historyStep("ArrowDown", box("x", 1), 2, history.length)).toBe(-1);
    expect(historyStep("ArrowUp", box("x", 1), 2, history.length)).toBeNull();
    expect(historyText(history, 2, "typing")).toBe("typing");
    expect(historyText(history, 0, "typing")).toBe("only");
  });
});
