import { Eraser } from "lucide-react";
import { useState } from "react";
import HoldButton from "@/components/kokonutui/hold-button";
import type { TidyItem } from "@/lib/api";
import { formatSize, selectionSummary, tidyGroups, tidyItemName, tidyQueuedText, toggleAll, toggled } from "./tidy-card-view";

const loadApi = () => import("@/lib/api").then((m) => m.api);

/** One kind of item: its label, then a tick box per item with its size and why it is listed. */
function TidyGroup({ label, items, selected, disabled, onToggle }: { label: string; items: TidyItem[]; selected: ReadonlySet<string>; disabled: boolean; onToggle: (id: string) => void }) {
  return (
    <fieldset className="kit-fieldset space-y-1 text-xs">
      <legend className="kit-legend">
        {label} ({items.length})
      </legend>
      {items.map((it) => (
        <label className="flex min-w-0 items-start gap-2" key={it.id}>
          <input checked={selected.has(it.id)} className="kit-check mt-0.5" disabled={disabled} onChange={() => onToggle(it.id)} type="checkbox" />
          <span className="min-w-0 flex-1">
            <span className="block truncate font-mono" title={tidyItemName(it)}>
              {tidyItemName(it)}
            </span>
            <span className="block text-muted-foreground">{it.reason}</span>
          </span>
          <span className="shrink-0 text-muted-foreground tabular-nums">{formatSize(it.size)}</span>
        </label>
      ))}
    </fieldset>
  );
}

/**
 * The tidy-up list (command menu): what the project likely no longer uses, by kind, with a size and
 * a reason each. Nothing is ticked at first; Remove selected (hold to confirm) asks StreamHub to remove
 * the ticked items, each checked again first, as one change set that Undo brings back.
 */
export function TidyCard({ items, text, restored }: { items: TidyItem[]; text: string; restored: boolean }) {
  const [selected, setSelected] = useState<Set<string>>(() => new Set());
  const [done, setDone] = useState("");
  const [busy, setBusy] = useState(false);
  if (restored) return null; // an earlier list: the command menu makes a fresh one
  const sum = selectionSummary(items, selected);
  const locked = busy || Boolean(done);
  const remove = async () => {
    setBusy(true);
    try {
      await (await loadApi()).tidyApply([...selected]);
      setDone(tidyQueuedText(sum.count));
    } catch (e) {
      setDone((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="kit-panel space-y-3 text-sm">
      <div className="flex items-center gap-2 font-medium">
        <Eraser className="h-4 w-4 text-muted-foreground" />
        {text}
      </div>
      {items.length > 0 && (
        <>
          <label className="kit-check text-xs">
            <input checked={items.every((i) => selected.has(i.id))} disabled={locked} onChange={() => setSelected(toggleAll(items, selected))} type="checkbox" />
            Select all
          </label>
          {tidyGroups(items).map((g) => (
            <TidyGroup disabled={locked} items={g.items} key={g.kind} label={g.label} onToggle={(id) => setSelected(toggled(selected, id))} selected={selected} />
          ))}
          {done ? (
            <div className="text-muted-foreground text-xs">{done}</div>
          ) : (
            <div className="flex flex-wrap items-center gap-3">
              <HoldButton
                className="h-10 min-w-44"
                disabled={busy || !sum.count}
                holdDuration={1200}
                holdingLabel="Keep holding..."
                label="Hold to remove selected"
                onHoldComplete={() => void remove()}
                variant="grey"
              />
              <span className="text-muted-foreground text-xs">{sum.text}</span>
            </div>
          )}
        </>
      )}
    </div>
  );
}
