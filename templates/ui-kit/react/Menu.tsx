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

const MOVE_KEYS = ["ArrowDown", "ArrowUp", "Home", "End"];

// The item a key moves to among n items from item i: Home and End go to the ends, the arrows wrap around.
function nextIndex(key: string, i: number, n: number) {
  if (key === "Home") return 0;
  if (key === "End") return n - 1;
  return (i + (key === "ArrowDown" ? 1 : -1) + n) % n;
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
    all[nextIndex(key, i, all.length)].focus();
  };
  // Escape closes and goes back to the menu button; Tab closes and lets focus move on.
  const close = (key: string) => {
    setOpen(false);
    if (key === "Escape") button.current?.focus();
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
          if (MOVE_KEYS.includes(e.key)) {
            e.preventDefault();
            move(e.key);
          } else if (e.key === "Escape" || e.key === "Tab") close(e.key);
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
