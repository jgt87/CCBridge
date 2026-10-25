import { describe, expect, it } from "vitest";
import { buildApplyRequest, chosenLayouts, defaultPair, endOptions, needsCheck, normalisePlan, pickProblem, planSummary, pptxRethemeItem, slideLabel } from "./pptx-retheme-view";

// As Windows PowerShell 5.1 sends it: a one-item list arrives as the item itself.
const raw = {
  template: "Brand.potx",
  content: "Decks/talk.pptx",
  layouts: ["Cover", "Titel en inhoud", "Alleen titel", "Leeg"],
  slides: [
    { index: 1, title: "Quarterly results", layout: "Cover", sure: true, why: "same purpose: Title Slide", heading: 0, from: "Title Slide" },
    { index: 2, title: "Executive Snapshot", layout: "Alleen titel", sure: false, why: "same purpose: Title Only", heading: 5, extra: "kept" },
  ],
  templateSlides: { index: 1, title: "ACME opening" },
  start: 1,
  end: "0",
  notes: "The content deck is 13.33 x 7.5 in and the template 10 x 5.63 in.",
};

describe("pptx retheme card", () => {
  it("reads the event's plan, with single items as lists and extra fields kept", () => {
    const p = normalisePlan(raw);
    expect(p.step).toBe("plan");
    expect(p.templateSlides).toEqual([{ index: 1, title: "ACME opening" }]);
    expect(p.notes).toHaveLength(1);
    expect(p.end).toBe(0);
    expect(p.slides[1].heading).toBe(5);
    expect(p.slides[1].extra).toBe("kept");
    expect(normalisePlan(null).slides).toEqual([]);
  });

  it("makes the transcript item from the event", () => {
    const item = pptxRethemeItem({ seq: 7, pptx: raw, restored: true });
    expect(item.kind).toBe("pptxRetheme");
    expect(item.seq).toBe(7);
    expect(item.restored).toBe(true);
    expect(item.plan.slides).toHaveLength(2);
    expect(pptxRethemeItem({ seq: 1 }).plan.step).toBe("plan");
  });

  it("marks only unsure slides the person has not changed", () => {
    const p = normalisePlan(raw);
    expect(needsCheck(p.slides[0], {})).toBe(false);
    expect(needsCheck(p.slides[1], {})).toBe(true);
    expect(needsCheck(p.slides[1], { 2: "Leeg" })).toBe(false);
    expect(planSummary(p, {})).toBe("2 slides, 1 to check");
    expect(planSummary(p, { 2: "Alleen titel" })).toBe("2 slides");
    expect(planSummary({ ...p, copilot: true }, {})).toBe("2 slides, 1 to check (layouts proposed by Copilot)");
  });

  it("labels slides and offers none or a template slide as start and end", () => {
    expect(slideLabel({ index: 3, title: "" })).toBe("3. (no title)");
    expect(slideLabel({ index: 1, title: "x".repeat(80) })).toHaveLength(63);
    expect(endOptions(normalisePlan(raw))).toEqual([
      { value: 0, label: "None" },
      { value: 1, label: "1. ACME opening" },
    ]);
  });

  it("builds the apply request with the person's layouts over the proposal", () => {
    const p = normalisePlan(raw);
    expect(chosenLayouts(p, { 2: "Leeg" })).toEqual({ 1: "Cover", 2: "Leeg" });
    const r = buildApplyRequest(p, { 2: "Leeg" }, { start: 1, end: 0, templateStyles: true, keepBackgrounds: false });
    expect(r).toEqual({
      template: "Brand.potx",
      content: "Decks/talk.pptx",
      choices: { layouts: { "1": "Cover", "2": "Leeg" }, titles: { "1": 0, "2": 5 }, start: 1, end: 0, templateStyles: true, keepBackgrounds: false, elements: {}, kinds: {} },
    });
  });

  it("starts the pick step with a likely template and the newest other deck", () => {
    const pick = normalisePlan({ step: "pick", templates: ["Decks/talk.pptx", "House style.potx"], contents: ["Decks/talk.pptx", "Runbooks/Exports/talk-branded-20260101-0000.pptx"] });
    expect(pick.step).toBe("pick");
    expect(defaultPair(pick)).toEqual({ template: "House style.potx", content: "Decks/talk.pptx" });
    expect(pickProblem("a.pptx", "a.pptx")).toMatch(/different files/);
    expect(pickProblem("", "a.pptx")).toBe("Choose a template.");
    expect(pickProblem("t.potx", "a.pptx")).toBe("");
  });
});
