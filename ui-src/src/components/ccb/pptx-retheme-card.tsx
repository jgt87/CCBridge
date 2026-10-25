import { Presentation, Sparkles } from "lucide-react";
import { useState } from "react";
import { cn } from "@/lib/utils";
import { FontNote, KindChoices, SlideElements } from "./pptx-choices";
import {
  buildApplyRequest,
  choiceSummary,
  chosenLayouts,
  defaultPair,
  endOptions,
  needsCheck,
  type PptxPlan,
  pickProblem,
  planSummary,
  slideElements,
  slideLabel,
} from "./pptx-retheme-view";

const loadApi = () => import("@/lib/api").then((m) => m.api);

/** Step one: which deck is the template and which holds the content. */
function PickStep({ plan }: { plan: PptxPlan }) {
  const first = defaultPair(plan);
  const [template, setTemplate] = useState(first.template);
  const [content, setContent] = useState(first.content);
  const [done, setDone] = useState("");
  const [busy, setBusy] = useState(false);
  const problem = pickProblem(template, content);
  const propose = async () => {
    setBusy(true);
    try {
      await (await loadApi()).pptxPlan(template, content);
      setDone("StreamHub is reading both decks; the proposal comes next.");
    } catch (e) {
      setDone((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  if (!plan.templates.length) return <div className="text-muted-foreground text-xs">This project has no PowerPoint files. Add the template and the deck to the project first.</div>;
  return (
    <div className="space-y-2">
      <label className="flex flex-col gap-1 text-xs">
        Template (.pptx or .potx)
        <select className="kit-select h-8 min-h-8 text-xs" disabled={busy || Boolean(done)} onChange={(e) => setTemplate(e.target.value)} value={template}>
          {plan.templates.map((t) => (
            <option key={t} value={t}>
              {t}
            </option>
          ))}
        </select>
      </label>
      <label className="flex flex-col gap-1 text-xs">
        Content deck
        <select className="kit-select h-8 min-h-8 text-xs" disabled={busy || Boolean(done)} onChange={(e) => setContent(e.target.value)} value={content}>
          <option value="">Choose...</option>
          {plan.contents.map((c) => (
            <option key={c} value={c}>
              {c}
            </option>
          ))}
        </select>
      </label>
      {done ? (
        <div className="text-muted-foreground text-xs">{done}</div>
      ) : (
        <button className="kit-btn kit-btn--primary kit-btn--sm" disabled={busy || Boolean(problem)} onClick={() => void propose()} title={problem} type="button">
          Propose layouts
        </button>
      )}
    </div>
  );
}

/** One content slide: its title and the layout it gets, marked "check" while the rules were not sure. */
function SlideRow({ plan, slide, value, check, disabled, onChange }: { plan: PptxPlan; slide: PptxPlan["slides"][number]; value: string; check: boolean; disabled: boolean; onChange: (layout: string) => void }) {
  return (
    <div className="flex items-center gap-2 text-xs">
      <span className="min-w-0 flex-1 truncate" title={slide.from ? `Now on "${slide.from}"` : undefined}>
        {slideLabel(slide)}
      </span>
      {check && (
        <span className="kit-badge min-h-0 shrink-0 px-1 py-px text-[10px] uppercase tracking-wide" title={`Not sure: ${slide.why}. Pick the layout yourself.`}>
          check
        </span>
      )}
      <select aria-label={`Layout for slide ${slide.index}`} className="kit-select h-8 min-h-8 w-48 shrink-0 text-xs" disabled={disabled} onChange={(e) => onChange(e.target.value)} title={slide.why} value={value}>
        {plan.layouts.map((l) => (
          <option key={l} value={l}>
            {l}
          </option>
        ))}
      </select>
    </div>
  );
}

/** Step two: the layout per slide, start and end slides, two options; Ask Copilot and Apply. */
function PlanStep({ plan }: { plan: PptxPlan }) {
  const [changes, setChanges] = useState<Record<number, string>>({});
  const [start, setStart] = useState(plan.start);
  const [end, setEnd] = useState(plan.end);
  const [templateStyles, setTemplateStyles] = useState(false);
  const [keepBackgrounds, setKeepBackgrounds] = useState(false);
  const [elementChoices, setElementChoices] = useState<Record<string, string>>({});
  const [kindChoices, setKindChoices] = useState<Record<string, string>>({});
  const [asked, setAsked] = useState("");
  const [done, setDone] = useState("");
  const [busy, setBusy] = useState(false);
  const chosen = chosenLayouts(plan, changes);
  const askElement = async (key: string) => {
    try {
      await (await loadApi()).pptxAskElement(plan.template, plan.content, key);
      setAsked("Copilot gets this element's structure (no slide text) and suggests a look; its answer comes as a line below.");
    } catch (e) {
      setAsked((e as Error).message);
    }
  };
  const locked = busy || Boolean(done);
  const run = async (what: "apply" | "ask") => {
    setBusy(true);
    try {
      const api = await loadApi();
      if (what === "ask") {
        await api.pptxAsk(plan.template, plan.content);
        setDone("Copilot gets the slides' structure (no full text) and proposes layouts; a new card follows.");
      } else {
        const r = await api.pptxApply(buildApplyRequest(plan, changes, { start, end, templateStyles, keepBackgrounds, elements: elementChoices, kinds: kindChoices }));
        setDone(`Applying the template. The new deck goes to ${r.path}; the template and the content deck stay as they are.`);
      }
    } catch (e) {
      setDone((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const ends = endOptions(plan);
  const looks = choiceSummary(plan, elementChoices, kindChoices);
  return (
    <div className="space-y-3">
      <div className="text-muted-foreground text-xs">
        {plan.content} onto {plan.template}: {planSummary(plan, changes)}
      </div>
      {plan.notes.map((n) => (
        <div className="kit-notice text-xs" key={n}>
          {n}
        </div>
      ))}
      {plan.errors.length > 0 && <div className="text-muted-foreground text-xs">{"Left out of the answer from Copilot: " + plan.errors.join("; ")}</div>}
      {looks && (
        <div className="space-y-2">
          <div className="text-muted-foreground text-xs">{`${looks}. Pick a look per element below (Keep as it is changes nothing); a look whose text would not read on the template is not offered.`}</div>
          <KindChoices disabled={locked} kinds={plan.kinds} onChange={(k, o) => setKindChoices((c) => ({ ...c, [k]: o }))} value={kindChoices} />
          <FontNote plan={plan} />
          {asked && <div className="text-muted-foreground text-xs">{asked}</div>}
        </div>
      )}
      <ul className="space-y-1.5">
        {plan.slides.map((s) => (
          <li className="space-y-1.5" key={s.index}>
            <SlideRow check={needsCheck(s, changes)} disabled={locked} onChange={(l) => setChanges((c) => ({ ...c, [s.index]: l }))} plan={plan} slide={s} value={chosen[s.index]} />
            <SlideElements
              disabled={locked}
              elementChoices={elementChoices}
              elements={slideElements(s)}
              kindChoices={kindChoices}
              onAsk={(k) => void askElement(k)}
              onChoose={(k, o) => setElementChoices((c) => ({ ...c, [k]: o }))}
            />
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap gap-3 text-xs">
        <label className="flex items-center gap-1.5">
          Start slide
          <select className="kit-select h-8 min-h-8 text-xs" disabled={locked} onChange={(e) => setStart(Number(e.target.value))} value={start}>
            {ends.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>
        </label>
        <label className="flex items-center gap-1.5">
          End slide
          <select className="kit-select h-8 min-h-8 text-xs" disabled={locked} onChange={(e) => setEnd(Number(e.target.value))} value={end}>
            {ends.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>
        </label>
      </div>
      <div className="space-y-1">
        <label className="kit-check text-xs" title="Fonts and colours typed into titles and text placeholders go; the template's text styles apply. Text boxes keep theirs.">
          <input checked={templateStyles} disabled={locked} onChange={(e) => setTemplateStyles(e.target.checked)} type="checkbox" />
          {"Use the template's text styles"}
        </label>
        <label className="kit-check text-xs" title="Off: a light background the deck paints itself is removed, so the template's background shows. Dark backgrounds always stay.">
          <input checked={keepBackgrounds} disabled={locked} onChange={(e) => setKeepBackgrounds(e.target.checked)} type="checkbox" />
          {"Keep the deck's own backgrounds"}
        </label>
      </div>
      {done ? (
        <div className="text-muted-foreground text-xs">{done}</div>
      ) : (
        <div className="flex flex-wrap gap-2">
          <button className="kit-btn kit-btn--primary kit-btn--sm" disabled={busy} onClick={() => void run("apply")} type="button">
            Apply
          </button>
          <button className="kit-btn kit-btn--ghost kit-btn--sm" disabled={busy} onClick={() => void run("ask")} title="Copilot proposes the layouts from the slides' structure: shape kinds, places and the first 60 characters of text" type="button">
            <Sparkles className="h-3.5 w-3.5" />
            Ask Copilot
          </button>
        </div>
      )}
    </div>
  );
}

/**
 * Apply a PowerPoint template to a content deck (on request, from the command menu). StreamHub
 * proposes the template layout per slide and the template's start and end slides; the person changes
 * what they want and applies. The new deck goes to Runbooks/Exports; both decks stay unchanged.
 */
export function PptxRethemeCard({ plan, restored }: { plan: PptxPlan; restored: boolean }) {
  if (restored) return null; // an earlier card: its buttons would act on decks that may have changed
  return (
    <div className="kit-panel space-y-3 text-sm">
      <div className={cn("flex items-center gap-2 font-medium")}>
        <Presentation className="h-4 w-4 text-muted-foreground" />
        Apply a PowerPoint template
      </div>
      {plan.step === "pick" ? <PickStep plan={plan} /> : <PlanStep plan={plan} />}
    </div>
  );
}
