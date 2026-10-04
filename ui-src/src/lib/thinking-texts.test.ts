import { describe, expect, it } from "vitest";
import { FUNNY_WAITING, FUNNY_WRITING, thinkingTexts, WAITING, WRITING } from "./thinking-texts";

describe("thinking texts", () => {
  it("never name the assistant's product", () => {
    for (const t of [...WAITING, ...WRITING, ...FUNNY_WAITING, ...FUNNY_WRITING]) expect(t).not.toMatch(/copilot|microsoft|chatgpt|claude/i);
  });
  it("start with the plain lines and use every light line once", () => {
    const list = thinkingTexts("waiting", 42);
    expect(list.slice(0, WAITING.length)).toEqual(WAITING);
    expect(list.filter((t) => FUNNY_WAITING.includes(t)).sort()).toEqual([...FUNNY_WAITING].sort());
    expect(thinkingTexts("writing", 7).slice(0, WRITING.length)).toEqual(WRITING);
  });
  it("keep one order per seed and change it between seeds", () => {
    expect(thinkingTexts("waiting", 5)).toEqual(thinkingTexts("waiting", 5));
    expect(thinkingTexts("waiting", 5)).not.toEqual(thinkingTexts("waiting", 6));
  });
});
