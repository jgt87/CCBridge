import { Presentation } from "lucide-react";
import { useState } from "react";
import { buildProblem, type PptxOutlineItem } from "./pptx-outline-view";

const loadApi = () => import("@/lib/api").then((m) => m.api);

/**
 * Build a deck from an outline (command menu, or offered after Copilot wrote one): choose the outline
 * and the template, then Build. StreamHub puts the outline's slides on the template's layouts and saves
 * the deck in Runbooks/Exports; nothing is built until the button is pressed.
 */
export function PptxOutlineCard({ item }: { item: PptxOutlineItem }) {
  const [outline, setOutline] = useState(item.outline);
  const [template, setTemplate] = useState(item.template);
  const [done, setDone] = useState("");
  const [busy, setBusy] = useState(false);
  if (item.restored) return null; // an earlier card: the outlines may have changed since
  const problem = buildProblem(outline, template);
  const locked = busy || Boolean(done);
  const build = async () => {
    setBusy(true);
    try {
      const r = await (await loadApi()).pptxBuild(outline, template);
      setDone(`Building the deck. It goes to ${r.path}; the outline and the template stay as they are.`);
    } catch (e) {
      setDone((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="kit-panel space-y-3 text-sm">
      <div className="flex items-center gap-2 font-medium">
        <Presentation className="h-4 w-4 text-muted-foreground" />
        Build a deck from an outline
      </div>
      {item.text && <div className="text-muted-foreground text-xs">{item.text}</div>}
      {!item.outlines.length ? (
        <div className="text-muted-foreground text-xs">This project has no deck outline yet. Ask Copilot for a presentation: it writes the outline as Work/NAME.deck.json, and this card comes back with it.</div>
      ) : !item.templates.length ? (
        <div className="text-muted-foreground text-xs">This project has no PowerPoint template. Add your template (.pptx or .potx) to the project first.</div>
      ) : (
        <>
          <label className="flex flex-col gap-1 text-xs">
            Deck outline
            <select className="kit-select h-8 min-h-8 text-xs" disabled={locked} onChange={(e) => setOutline(e.target.value)} value={outline}>
              {item.outlines.map((o) => (
                <option key={o} value={o}>
                  {o}
                </option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1 text-xs">
            Template (.pptx or .potx)
            <select className="kit-select h-8 min-h-8 text-xs" disabled={locked} onChange={(e) => setTemplate(e.target.value)} value={template}>
              {item.templates.map((t) => (
                <option key={t} value={t}>
                  {t}
                </option>
              ))}
            </select>
          </label>
          {done ? (
            <div className="text-muted-foreground text-xs">{done}</div>
          ) : (
            <button className="kit-btn kit-btn--primary kit-btn--sm" disabled={busy || Boolean(problem)} onClick={() => void build()} title={problem} type="button">
              Build
            </button>
          )}
        </>
      )}
    </div>
  );
}
