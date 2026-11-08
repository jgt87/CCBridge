/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { useEffect, useId, useRef, useState } from "react";

export interface MultiOption {
  value: string;
  label: string;
}

/** A filter for several values: check boxes with a search; nothing ticked means all. */
export function MultiSelect({ label, options, value, onChange }: { label: string; options: MultiOption[]; value: string[]; onChange: (values: string[]) => void }) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const wrap = useRef<HTMLDivElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const panelId = useId();
  useEffect(() => {
    if (!open) return;
    search.current?.focus();
    const outside = (e: MouseEvent) => {
      if (wrap.current && !wrap.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("click", outside);
    return () => document.removeEventListener("click", outside);
  }, [open]);
  const chosen = options.filter((o) => value.includes(o.value));
  const text = !chosen.length || chosen.length === options.length ? "All" : chosen.length === 1 ? chosen[0].label : chosen.length + " selected";
  const active = chosen.length > 0 && chosen.length < options.length;
  const q = query.trim().toLowerCase();
  const toggle = (v: string, on: boolean) => onChange(on ? [...value.filter((x) => x !== v), v] : value.filter((x) => x !== v));
  return (
    <div
      className={"kit-multi" + (active ? " is-active" : "")}
      onBlur={(e) => {
        // Tab out of the panel closes it.
        if (open && e.relatedTarget && !e.currentTarget.contains(e.relatedTarget as Node)) setOpen(false);
      }}
      onKeyDown={(e) => {
        if (e.key === "Escape" && open) {
          e.preventDefault(); // the panel only: a dialog or side panel around it stays open
          e.stopPropagation();
          setOpen(false);
          button.current?.focus();
        }
      }}
      ref={wrap}
    >
      {/* The button opens a panel of check boxes (a dialog, not a menu). */}
      <button
        aria-controls={panelId}
        aria-expanded={open}
        aria-haspopup="dialog"
        className="kit-input kit-multi__button"
        onClick={() => {
          setQuery("");
          setOpen((o) => !o);
        }}
        ref={button}
        type="button"
      >
        {label}: {text}
      </button>
      <div aria-label={label} className="kit-multi__panel" hidden={!open} id={panelId} role="dialog">
        <input aria-label={"Search " + label} className="kit-input" onChange={(e) => setQuery(e.target.value)} placeholder="Search" ref={search} type="search" value={query} />
        <ul className="kit-multi__list">
          {options.map((o) => (
            <li hidden={!!q && !o.label.toLowerCase().includes(q)} key={o.value}>
              <label>
                <input checked={value.includes(o.value)} onChange={(e) => toggle(o.value, e.target.checked)} type="checkbox" />
                {o.label}
              </label>
            </li>
          ))}
        </ul>
        <div className="kit-multi__actions">
          <button className="kit-btn kit-btn--sm kit-btn--ghost" onClick={() => onChange(options.map((o) => o.value))} type="button">
            Select all
          </button>
          <button className="kit-btn kit-btn--sm kit-btn--ghost" onClick={() => onChange([])} type="button">
            Clear
          </button>
        </div>
      </div>
    </div>
  );
}
