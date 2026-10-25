// Texts and request building of the "Apply a PowerPoint template" card (pptx-retheme-card.tsx). Which
// layout a slide gets, and whether a slide needs a look, is decided by StreamHub
// (lib/PptxLayoutMatch.psm1) or by Copilot on request; the card only shows it and lets the person change it.

/** One content slide in the plan. Later steps may add fields (per-element choices); keep them. */
export interface PptxSlidePlan {
  index: number;
  title: string;
  /** The template layout proposed for this slide. */
  layout: string;
  /** False: the fixed rules were not sure (the card marks it "check"). */
  sure: boolean;
  /** Why this layout: "same layout name", "same purpose: Title Only", "Copilot"... */
  why: string;
  /** The id of the plain text box that becomes the slide's title (0: none). */
  heading: number;
  /** The layout the slide is on in the content deck. */
  from?: string;
  hidden?: boolean;
  notes?: boolean;
  [extra: string]: unknown;
}

export interface PptxTemplateSlide {
  index: number;
  title: string;
}

/** The pptx-plan event: the decks to choose from (step "pick"), or the proposal for a chosen pair. */
export interface PptxPlan {
  step: "pick" | "plan";
  template: string;
  content: string;
  /** step pick: the project's decks (templates may be .potx), newest first. */
  templates: string[];
  contents: string[];
  layouts: string[];
  slides: PptxSlidePlan[];
  templateSlides: PptxTemplateSlide[];
  /** Template slide numbers kept before and after the content (0: none). */
  start: number;
  end: number;
  notes: string[];
  /** The mapping came from Copilot; errors are what StreamHub refused from its answer. */
  copilot: boolean;
  errors: string[];
  /** The kinds of element without brand formatting, for "all tables: ..." (lib/PptxChoices.psm1). */
  kinds: PptxKind[];
  /** The typefaces the previews draw with (checked in the browser; a stand-in when missing). */
  fonts: string[];
}

/** What Apply sends: the same choices object Invoke-PptxRetheme takes (-Choices). */
export interface PptxApplyRequest {
  template: string;
  content: string;
  choices: {
    layouts: Record<string, string>;
    titles: Record<string, number>;
    start: number;
    end: number;
    templateStyles: boolean;
    keepBackgrounds: boolean;
    /** Per element ("slide:shape id") the option chosen on the card (lib/PptxChoices.psm1). */
    elements: Record<string, string>;
    /** Per kind of element ("table", "shape"...) the option for all of them. */
    kinds: Record<string, string>;
  };
}

/** One look StreamHub offers for an element without brand formatting; drawing is a JSON preview (pptx-drawing.ts). */
export interface PptxOption {
  id: string;
  label: string;
  /** template, kit or keep. */
  group: string;
  drawing: string;
}

/** An element of a content slide that carries no brand formatting, with its ranked options. */
export interface PptxElement {
  key: string;
  slide: number;
  id: number;
  /** table, textbox, shape, chart or heading. */
  kind: string;
  label: string;
  options: PptxOption[];
  /** The option it gets when the person chooses nothing ("keep", or "title-placeholder" for the core's heading). */
  default: string;
}

/** A kind of element on the deck: how many, and the options every one of them offers. */
export interface PptxKind {
  kind: string;
  label: string;
  count: number;
  options: { id: string; label: string }[];
}

/** The calls the card makes (api.ts: pptxPlan, pptxAsk, pptxAskElement, pptxApply). */
export interface PptxRethemeApi {
  pptxPlan: (template: string, content: string) => Promise<{ ok: boolean; queued: string }>;
  pptxAsk: (template: string, content: string) => Promise<{ ok: boolean; queued: string }>;
  pptxAskElement: (template: string, content: string, element: string) => Promise<{ ok: boolean; queued: string }>;
  pptxApply: (request: PptxApplyRequest) => Promise<{ ok: boolean; queued: string; path: string }>;
}

function list<T>(v: unknown): T[] {
  // Windows PowerShell 5.1 sends a one-item list as the item itself.
  return Array.isArray(v) ? (v as T[]) : v === null || v === undefined || v === "" ? [] : [v as T];
}

function normaliseElement(e: Record<string, unknown>): PptxElement {
  return {
    key: String(e.key ?? ""),
    slide: Number(e.slide) || 0,
    id: Number(e.id) || 0,
    kind: String(e.kind ?? ""),
    label: String(e.label ?? ""),
    options: list<Record<string, unknown>>(e.options).map((o) => ({ id: String(o.id ?? ""), label: String(o.label ?? ""), group: String(o.group ?? ""), drawing: String(o.drawing ?? "") })),
    default: String(e.default ?? "keep"),
  };
}

/** A slide's elements without brand formatting (the plan's slides carry them as "elements"). */
export function slideElements(s: PptxSlidePlan): PptxElement[] {
  return list<Record<string, unknown>>(s.elements).map(normaliseElement);
}

/** The option an element gets now: its own choice, else its kind's when it offers that, else its default. */
export function effectiveOption(e: PptxElement, elementChoices: Record<string, string>, kindChoices: Record<string, string>): string {
  const own = elementChoices[e.key];
  if (own && e.options.some((o) => o.id === own)) return own;
  const kind = kindChoices[e.kind];
  if (kind && e.options.some((o) => o.id === kind)) return kind;
  return e.default;
}

/** How many elements take a look other than "Keep as it is". */
export function choiceSummary(plan: PptxPlan, elementChoices: Record<string, string>, kindChoices: Record<string, string>): string {
  const all = plan.slides.flatMap(slideElements);
  if (!all.length) return "";
  const changed = all.filter((e) => effectiveOption(e, elementChoices, kindChoices) !== "keep").length;
  return `${all.length} element${all.length === 1 ? "" : "s"} without brand formatting, ${changed} to restyle`;
}

/** The event's plan with every list a list and every number a number. */
export function normalisePlan(raw: Record<string, unknown> | undefined | null): PptxPlan {
  const r = raw ?? {};
  const slides = list<Record<string, unknown>>(r.slides).map((s) => ({
    ...s,
    index: Number(s.index) || 0,
    title: String(s.title ?? ""),
    layout: String(s.layout ?? ""),
    sure: s.sure === true,
    why: String(s.why ?? ""),
    heading: Number(s.heading) || 0,
  })) as PptxSlidePlan[];
  return {
    step: r.step === "pick" ? "pick" : "plan",
    template: String(r.template ?? ""),
    content: String(r.content ?? ""),
    templates: list<string>(r.templates),
    contents: list<string>(r.contents),
    layouts: list<string>(r.layouts),
    slides,
    templateSlides: list<Record<string, unknown>>(r.templateSlides).map((t) => ({ index: Number(t.index) || 0, title: String(t.title ?? "") })),
    start: Number(r.start) || 0,
    end: Number(r.end) || 0,
    notes: list<string>(r.notes),
    copilot: r.copilot === true,
    errors: list<string>(r.errors),
    kinds: list<Record<string, unknown>>(r.kinds).map((k) => ({
      kind: String(k.kind ?? ""),
      label: String(k.label ?? ""),
      count: Number(k.count) || 0,
      options: list<Record<string, unknown>>(k.options).map((o) => ({ id: String(o.id ?? ""), label: String(o.label ?? "") })),
    })),
    fonts: list<string>(r.fonts),
  };
}

function cut(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}\u2026` : text;
}

/** The transcript item of a pptx-plan event (its plan travels in the event's "pptx" field). */
export interface PptxRethemeItem {
  kind: "pptxRetheme";
  seq: number;
  plan: PptxPlan;
  restored: boolean;
}

export function pptxRethemeItem(e: { seq: number; restored?: boolean; pptx?: unknown }): PptxRethemeItem {
  return { kind: "pptxRetheme", seq: e.seq, plan: normalisePlan(e.pptx as Record<string, unknown> | undefined), restored: Boolean(e.restored) };
}

/** A slide's line: its number and title. */
export function slideLabel(s: Pick<PptxSlidePlan, "index" | "title">): string {
  return `${s.index}. ${s.title ? cut(s.title, 60) : "(no title)"}`;
}

/** The layouts each slide gets now: the proposal, with the person's changes over it. */
export function chosenLayouts(plan: PptxPlan, changes: Record<number, string>): Record<number, string> {
  return Object.fromEntries(plan.slides.map((s) => [s.index, changes[s.index] ?? s.layout]));
}

/** A slide still to look at: the rules were not sure and the person has not picked a layout. */
export function needsCheck(s: PptxSlidePlan, changes: Record<number, string>): boolean {
  return !s.sure && changes[s.index] === undefined;
}

/** The card's summary line: how many slides, how many to check. */
export function planSummary(plan: PptxPlan, changes: Record<number, string>): string {
  const check = plan.slides.filter((s) => needsCheck(s, changes)).length;
  const n = plan.slides.length;
  return `${n} slide${n === 1 ? "" : "s"}${check ? `, ${check} to check` : ""}${plan.copilot ? " (layouts proposed by Copilot)" : ""}`;
}

/** The choices for the start and end slide: none, or one of the template's slides. */
export function endOptions(plan: Pick<PptxPlan, "templateSlides">): { value: number; label: string }[] {
  return [{ value: 0, label: "None" }, ...plan.templateSlides.map((t) => ({ value: t.index, label: slideLabel(t) }))];
}

/** The Apply request, from the plan and the person's choices on the card. */
export function buildApplyRequest(
  plan: PptxPlan,
  changes: Record<number, string>,
  opts: { start: number; end: number; templateStyles: boolean; keepBackgrounds: boolean; elements?: Record<string, string>; kinds?: Record<string, string> }
): PptxApplyRequest {
  const chosen = chosenLayouts(plan, changes);
  const layouts: Record<string, string> = {};
  const titles: Record<string, number> = {};
  for (const s of plan.slides) {
    layouts[String(s.index)] = chosen[s.index];
    titles[String(s.index)] = s.heading;
  }
  // Only choices for elements the plan has, and kind choices that are not "leave each as it is".
  const keys = new Set(plan.slides.flatMap(slideElements).map((e) => e.key));
  const elements = Object.fromEntries(Object.entries(opts.elements ?? {}).filter(([k, v]) => keys.has(k) && v));
  const kinds = Object.fromEntries(Object.entries(opts.kinds ?? {}).filter(([, v]) => v));
  return {
    template: plan.template,
    content: plan.content,
    choices: { layouts, titles, start: opts.start, end: opts.end, templateStyles: opts.templateStyles, keepBackgrounds: opts.keepBackgrounds, elements, kinds },
  };
}

/** The pair the pick step starts with: a .potx or a name that says template, and the newest other deck. */
export function defaultPair(plan: Pick<PptxPlan, "templates" | "contents" | "template" | "content">): { template: string; content: string } {
  const template = plan.template || plan.templates.find((t) => /\.potx$/i.test(t) || /template|sjabloon|huisstijl|brand/i.test(t)) || plan.templates[0] || "";
  const content = plan.content || plan.contents.find((c) => c !== template && !/-branded-/.test(c)) || "";
  return { template, content };
}

/** Why Apply or Propose cannot start yet, or "" when it can. */
export function pickProblem(template: string, content: string): string {
  if (!template) return "Choose a template.";
  if (!content) return "Choose a content deck.";
  if (template === content) return "The template and the content deck must be different files.";
  return "";
}
