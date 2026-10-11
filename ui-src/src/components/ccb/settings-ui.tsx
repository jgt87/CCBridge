import type React from "react";
import { cn } from "@/lib/utils";

/**
 * The building blocks every Settings row uses, so labels, controls, the reset button and the
 * "Saved" note line up across the whole window: text on the left, then one fixed side column
 * (reset and Saved, empty when a row has none), then the control column of one fixed width, which
 * ends at the window's right padding.
 */

/** Width of every control (fields, choices, switches, buttons). */
export const CONTROL_W = "w-48";
/** Fields and selects: same width and height as the choice buttons. */
export const fieldClass = cn(CONTROL_W, "kit-input h-8 min-h-8");
/** Buttons in the control column. */
export const actionClass = cn(CONTROL_W, "kit-btn kit-btn--sm h-8");
/** Smaller buttons in a row under the text (for example Sign-in's actions). */
export const smallButtonClass = "kit-btn kit-btn--sm h-7 min-h-7";

export function SettingsGroup({ title, first = false, children }: { title: string; first?: boolean; children: React.ReactNode }) {
  return (
    <section className={cn("pt-3 pb-1", !first && "border-(--kit-border) border-t")}>
      <h3 className="mb-1 font-medium text-muted-foreground text-xs uppercase tracking-wide">{title}</h3>
      {children}
    </section>
  );
}

/**
 * One setting: title, help and notes on the left; the control; the side column (reset and Saved).
 * `below` spans the text and control columns, for wide controls (a command list) or extra buttons.
 */
export function SettingLine({
  title,
  help,
  notes,
  control,
  side,
  below,
}: {
  title: React.ReactNode;
  help?: React.ReactNode;
  notes?: React.ReactNode;
  control?: React.ReactNode;
  side?: React.ReactNode;
  below?: React.ReactNode;
}) {
  return (
    <div className="grid grid-cols-[minmax(0,1fr)_4.5rem_auto] items-start gap-x-3 py-2.5">
      <div className="min-w-0">
        <div className="text-sm">{title}</div>
        {help && <div className="text-muted-foreground text-xs">{help}</div>}
        {notes}
      </div>
      <div className="flex h-8 items-center justify-end gap-1">{side}</div>
      <div className={cn(CONTROL_W, "flex justify-end")}>{control}</div>
      {below && <div className="col-span-3 mt-2">{below}</div>}
    </div>
  );
}

/** A choice of a few options (On/Off, themes) in the control column. */
export function Segmented<T extends string>({
  options,
  value,
  onChange,
  disabled = false,
  label,
}: {
  options: { id: T; label: string; icon?: React.ReactNode }[];
  value: T | null;
  onChange: (v: T) => void;
  disabled?: boolean;
  label: string;
}) {
  return (
    <div aria-label={label} className={cn(CONTROL_W, "kit-segmented flex h-8 flex-nowrap")} role="group">
      {options.map((o) => (
        <button
          aria-pressed={value === o.id}
          className="inline-flex flex-1 items-center justify-center gap-1 px-1.5 py-0 text-xs disabled:opacity-40"
          disabled={disabled}
          key={o.id}
          onClick={() => value !== o.id && onChange(o.id)}
          type="button"
        >
          {o.icon}
          {o.label}
        </button>
      ))}
    </div>
  );
}
