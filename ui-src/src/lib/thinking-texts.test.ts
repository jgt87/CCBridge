import { describe, expect, it } from "vitest";
import { FUNNY_ACTIVITY, FUNNY_VISUAL, FUNNY_WAITING, FUNNY_WRITING, thinkingTexts, WAITING, WRITING, writesStyles } from "./thinking-texts";

describe("thinking texts", () => {
  it("never name the assistant's product", () => {
    for (const t of [...WAITING, ...WRITING, ...FUNNY_WAITING, ...FUNNY_WRITING, ...FUNNY_VISUAL]) expect(t).not.toMatch(/copilot|microsoft|chatgpt|claude/i);
  });
  it("never sound like skipping safety, security or rules (people in security read these too)", () => {
    const all = [...WAITING, ...WRITING, ...FUNNY_WAITING, ...FUNNY_WRITING, ...FUNNY_VISUAL, ...Object.values(FUNNY_ACTIVITY).flat()];
    const alarming =
      /safety|security|secur|compliance|committee|polic|audit|firewall|password|credential|bypass|ignor|disabl|overrid|hack|breach|exploit|sneak|evad|unauthori|weapon|kill|attack|steal|leak/i;
    for (const t of all) expect(t).not.toMatch(alarming);
  });
  it("start with the plain lines and use every light line once", () => {
    const list = thinkingTexts("waiting", 42);
    expect(list.slice(0, WAITING.length)).toEqual(WAITING);
    expect(list.filter((t) => FUNNY_WAITING.includes(t)).sort()).toEqual([...FUNNY_WAITING].sort());
    expect(thinkingTexts("writing", 7).slice(0, WRITING.length)).toEqual(WRITING);
  });
  it("use the art lines for visual work: a look request or a reply that writes styles", () => {
    const list = thinkingTexts("writing", 3, true);
    expect(list.slice(0, WRITING.length)).toEqual(WRITING);
    expect(list.filter((t) => FUNNY_VISUAL.includes(t)).sort()).toEqual([...FUNNY_VISUAL].sort());
    expect(list.some((t) => FUNNY_WRITING.includes(t))).toBe(false);
    expect(writesStyles("Sure.\n````text\nACTION edit styles/app.css\n")).toBe(true);
    expect(writesStyles("```text\nACTION write src/Theme.SCSS\n")).toBe(true);
    expect(writesStyles("```text\nACTION read styles/app.css\n")).toBe(false);
    expect(writesStyles("```text\nACTION edit index.html\n")).toBe(false);
  });
  it("keep one order per seed and change it between seeds", () => {
    expect(thinkingTexts("waiting", 5)).toEqual(thinkingTexts("waiting", 5));
    expect(thinkingTexts("waiting", 5)).not.toEqual(thinkingTexts("waiting", 6));
  });
});
