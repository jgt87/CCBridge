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
    // Escape closes the popover only (a dialog or side panel around it stays open), and not when another part already used it.
    const escape = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !e.defaultPrevented && !e.isComposing) {
        e.preventDefault();
        e.stopPropagation();
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
      <button aria-controls={id} aria-expanded={open} aria-haspopup="dialog" className={className} id={id + "-button"} onClick={() => setOpen((o) => !o)} ref={button} type="button">
        {label}
      </button>
      {/* A non-modal dialog named by its button: no aria-modal and no focus trap. */}
      <div aria-labelledby={id + "-button"} className={"kit-popover" + (align === "right" ? " kit-popover--right" : "")} hidden={!open} id={id} ref={panel} role="dialog" tabIndex={-1}>
        {head ? <p className="kit-popover__head">{head}</p> : null}
        {children}
      </div>
    </div>
  );
}
