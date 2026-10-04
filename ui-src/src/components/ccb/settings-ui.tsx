import type React from "react";
import { cn } from "@/lib/utils";

/**
 * The building blocks every Settings row uses, so labels, controls, the reset button and the
 * "Saved" note line up across the whole window: text on the left, a control column of one fixed
 * width, and one fixed side column on the right (empty when a row has no reset).
 */

/** Width of every control (fields, choices, switches, buttons). */
export const CONTROL_W = "w-48";
/** Fields and selects: same width and height as the choice buttons. */
export const fieldClass = cn(
  CONTROL_W,
  "h-8 rounded-md border border-black/10 bg-transparent px-2 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30"
);
/** Buttons in the control column. */
export const actionClass = cn(
  CONTROL_W,
  "h-8 rounded-md border border-black/10 px-2 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:border-white/10 dark:hover:bg-white/5"
);
/** Smaller buttons in a row under the text (for example Sign-in's actions). */
export const smallButtonClass =
  "h-7 rounded-md border border-black/10 px-2.5 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:border-white/10 dark:hover:bg-white/5";

export function SettingsGroup({ title, first = false, children }: { title: string; first?: boolean; children: React.ReactNode }) {
  return (
    <section className={cn("pt-3 pb-1", !first && "border-black/10 border-t dark:border-white/10")}>
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
    <div className="grid grid-cols-[minmax(0,1fr)_auto_4.5rem] items-start gap-x-3 py-2.5">
      <div className="min-w-0">
        <div className="text-sm">{title}</div>
        {help && <div className="text-muted-foreground text-xs">{help}</div>}
        {notes}
      </div>
      <div className={cn(CONTROL_W, "flex justify-end")}>{control}</div>
      <div className="flex h-8 items-center gap-1">{side}</div>
      {below && <div className="col-span-2 mt-2">{below}</div>}
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
    <div aria-label={label} className={cn(CONTROL_W, "flex h-8 rounded-md border border-black/10 p-0.5 dark:border-white/10")} role="radiogroup">
      {options.map((o) => (
        <button
          aria-checked={value === o.id}
          className={cn(
            "inline-flex flex-1 items-center justify-center gap-1 rounded px-1.5 text-xs disabled:opacity-40",
            value === o.id ? "bg-black/10 text-foreground dark:bg-white/15" : "text-muted-foreground hover:text-foreground"
          )}
          disabled={disabled}
          key={o.id}
          onClick={() => value !== o.id && onChange(o.id)}
          role="radio"
          type="button"
        >
          {o.icon}
          {o.label}
        </button>
      ))}
    </div>
  );
}
