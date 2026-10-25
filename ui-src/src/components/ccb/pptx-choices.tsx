import { Sparkles } from "lucide-react";
import { cn } from "@/lib/utils";
import { PptxDrawing } from "./pptx-drawing";
import { browserHasFont, missingFontsNote } from "./pptx-drawing-view";
import { effectiveOption, type PptxElement, type PptxKind, type PptxPlan } from "./pptx-retheme-view";

/** "For every table: ..." per kind of element on the deck (an option every element of that kind offers). */
export function KindChoices({ kinds, value, disabled, onChange }: { kinds: PptxKind[]; value: Record<string, string>; disabled: boolean; onChange: (kind: string, option: string) => void }) {
  const shown = kinds.filter((k) => k.options.length > 1);
  if (!shown.length) return null;
  return (
    <div className="flex flex-wrap gap-3 text-xs">
      {shown.map((k) => (
        <label className="flex items-center gap-1.5" key={k.kind}>
          {`Every ${k.label} (${k.count})`}
          <select aria-label={`Look for every ${k.label}`} className="kit-select h-8 min-h-8 max-w-56 text-xs" disabled={disabled} onChange={(e) => onChange(k.kind, e.target.value)} value={value[k.kind] ?? ""}>
            <option value="">Choose per element</option>
            {k.options.map((o) => (
              <option key={o.id} value={o.id}>
                {o.label}
              </option>
            ))}
          </select>
        </label>
      ))}
    </div>
  );
}

/** One element without brand formatting: its options as previews to pick from, and Ask Copilot. */
export function ElementChoice({
  element,
  chosen,
  disabled,
  onChoose,
  onAsk,
}: {
  element: PptxElement;
  chosen: string;
  disabled: boolean;
  onChoose: (option: string) => void;
  onAsk: () => void;
}) {
  return (
    <fieldset className="kit-fieldset space-y-1.5 text-xs">
      <legend className="kit-legend flex w-full min-w-0 items-center gap-2">
        <span className="min-w-0 flex-1 truncate" title={element.label}>
          {element.label}
        </span>
        <button className="kit-btn kit-btn--ghost kit-btn--sm shrink-0" disabled={disabled} onClick={onAsk} title="Copilot suggests one of these looks from the element's structure only (no slide text)" type="button">
          <Sparkles className="h-3.5 w-3.5" />
          Ask Copilot
        </button>
      </legend>
      <div className="flex flex-wrap gap-2" role="radiogroup">
        {element.options.map((o) => {
          const on = o.id === chosen;
          return (
            <button
              aria-checked={on}
              className={cn("flex w-28 flex-col items-stretch gap-1 rounded-(--kit-radius) border p-1 text-left", on ? "border-(--kit-accent) bg-(--kit-surface-2)" : "border-(--kit-border)")}
              disabled={disabled}
              key={o.id}
              onClick={() => onChoose(o.id)}
              role="radio"
              title={o.label}
              type="button"
            >
              <PptxDrawing className="h-14 w-full" json={o.drawing} label={`Preview: ${o.label}`} />
              <span className="line-clamp-2 leading-tight">{o.label}</span>
            </button>
          );
        })}
      </div>
    </fieldset>
  );
}

/** The elements of one slide, each with its options. */
export function SlideElements({
  elements,
  elementChoices,
  kindChoices,
  disabled,
  onChoose,
  onAsk,
}: {
  elements: PptxElement[];
  elementChoices: Record<string, string>;
  kindChoices: Record<string, string>;
  disabled: boolean;
  onChoose: (key: string, option: string) => void;
  onAsk: (key: string) => void;
}) {
  if (!elements.length) return null;
  return (
    <div className="ml-4 space-y-2">
      {elements.map((e) => (
        <ElementChoice chosen={effectiveOption(e, elementChoices, kindChoices)} disabled={disabled} element={e} key={e.key} onAsk={() => onAsk(e.key)} onChoose={(o) => onChoose(e.key, o)} />
      ))}
    </div>
  );
}

/** The note when a template font is missing in this browser (the previews then use a stand-in). */
export function FontNote({ plan }: { plan: PptxPlan }) {
  const note = missingFontsNote(plan.fonts, browserHasFont);
  return note ? <div className="text-muted-foreground text-xs">{note}</div> : null;
}
