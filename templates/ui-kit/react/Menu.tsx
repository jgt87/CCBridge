/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui profile-dropdown (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { type ReactNode, useEffect, useRef, useState } from "react";

export interface MenuItem {
  value: string;
  label: string;
  danger?: boolean;
  separatorBefore?: boolean;
}

/** A menu of actions (per row, or a user menu with a head): arrow keys move, Escape or a click beside it closes. */
export function Menu({ label, items, head, onPick, align = "right" }: { label: ReactNode; items: MenuItem[]; head?: ReactNode; onPick: (value: string) => void; align?: "left" | "right" }) {
  const [open, setOpen] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const list = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    list.current?.querySelector<HTMLButtonElement>(".kit-menu__item")?.focus();
    const outside = (e: MouseEvent) => {
      if (wrap.current && !wrap.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("click", outside);
    return () => document.removeEventListener("click", outside);
  }, [open]);
  const move = (key: string) => {
    const all = Array.from(list.current?.querySelectorAll<HTMLButtonElement>(".kit-menu__item:not([disabled])") ?? []);
    if (!all.length) return;
    const i = all.indexOf(document.activeElement as HTMLButtonElement);
    const next = key === "Home" ? 0 : key === "End" ? all.length - 1 : (i + (key === "ArrowDown" ? 1 : -1) + all.length) % all.length;
    all[next].focus();
  };
  return (
    <div className={"kit-menu" + (align === "left" ? " kit-menu--left" : "")} ref={wrap}>
      <button aria-expanded={open} aria-haspopup="menu" className="kit-btn" onClick={() => setOpen((o) => !o)} ref={button} type="button">
        {label}
      </button>
      <div
        className="kit-menu__list"
        hidden={!open}
        onKeyDown={(e) => {
          if (["ArrowDown", "ArrowUp", "Home", "End"].includes(e.key)) {
            e.preventDefault();
            move(e.key);
          } else if (e.key === "Escape" || e.key === "Tab") {
            setOpen(false);
            if (e.key === "Escape") button.current?.focus();
          }
        }}
        ref={list}
        role="menu"
      >
        {head ? <div className="kit-menu__head">{head}</div> : null}
        {items.map((it) => (
          <div key={it.value} role="none">
            {it.separatorBefore ? <hr className="kit-menu__sep" /> : null}
            <button
              className={"kit-menu__item" + (it.danger ? " kit-menu__item--danger" : "")}
              onClick={() => {
                setOpen(false);
                button.current?.focus();
                onPick(it.value);
              }}
              role="menuitem"
              type="button"
            >
              {it.label}
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
