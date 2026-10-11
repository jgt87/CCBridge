/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { type ReactNode, useEffect, useId, useRef, useState } from "react";

/** A small panel of content from a button (which columns to show, a setting): Escape or a click beside it closes it. For actions use Menu; for a form use Drawer. */
export function Popover({ label, children, align = "left", head, className = "kit-btn" }: { label: ReactNode; children: ReactNode; align?: "left" | "right"; head?: ReactNode; className?: string }) {
  const [open, setOpen] = useState(false);
  const id = useId();
  const wrap = useRef<HTMLDivElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const first = panel.current?.querySelector<HTMLElement>("input, select, textarea, button, a[href], [tabindex]:not([tabindex='-1'])");
    if (first) first.focus();
    else panel.current?.focus();
    const outside = (e: MouseEvent) => {
      if (wrap.current && !wrap.current.contains(e.target as Node)) setOpen(false);
    };
    const escape = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setOpen(false);
        button.current?.focus();
      }
    };
    document.addEventListener("click", outside);
    document.addEventListener("keydown", escape);
    return () => {
      document.removeEventListener("click", outside);
      document.removeEventListener("keydown", escape);
    };
  }, [open]);
  return (
    <div className="kit-popover-wrap" ref={wrap}>
      <button aria-controls={id} aria-expanded={open} className={className} onClick={() => setOpen((o) => !o)} ref={button} type="button">
        {label}
      </button>
      <div className={"kit-popover" + (align === "right" ? " kit-popover--right" : "")} hidden={!open} id={id} ref={panel} tabIndex={-1}>
        {head ? <p className="kit-popover__head">{head}</p> : null}
        {children}
      </div>
    </div>
  );
}
