/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui profile-dropdown (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { type ReactNode, type RefObject, useEffect, useLayoutEffect, useRef, useState } from "react";

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

/**
 * A menu of actions (per row, or a user menu with a head): arrow keys move, Escape or a click beside it closes.
 * buttonLabel makes the button an icon button with that name (label is then the icon, e.g. <Icon name="ellipsis" />).
 * contextRef makes it also the context menu of that element: a right click, Shift+F10 or the context menu key there
 * opens the same list at the pointer; the button stays the visible way to the same actions.
 */
export function Menu({ label, items, head, onPick, align = "right", buttonLabel, contextRef }: { label: ReactNode; items: MenuItem[]; head?: ReactNode; onPick: (value: string) => void; align?: "left" | "right"; buttonLabel?: string; contextRef?: RefObject<HTMLElement | null> }) {
  const [open, setOpen] = useState(false);
  const [point, setPoint] = useState<{ x: number; y: number } | null>(null);
  const [place, setPlace] = useState<{ left: number; top: number } | null>(null);
  const wrap = useRef<HTMLDivElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const back = useRef<HTMLElement | null>(null);
  const shut = () => {
    setOpen(false);
    setPoint(null);
    setPlace(null);
  };
  useEffect(() => {
    if (!open) return;
    list.current?.querySelector<HTMLButtonElement>(".kit-menu__item")?.focus();
    const outside = (e: MouseEvent) => {
      if (wrap.current && !wrap.current.contains(e.target as Node)) shut();
    };
    document.addEventListener("click", outside);
    return () => document.removeEventListener("click", outside);
  }, [open]);
  // As a context menu: at the pointer, kept inside the window; closed by scroll, wheel and resize.
  useLayoutEffect(() => {
    if (!open || !point || !list.current) return;
    const w = list.current.offsetWidth;
    const h = list.current.offsetHeight;
    setPlace({
      left: Math.round(point.x + w > window.innerWidth - 8 ? Math.max(8, point.x - w) : point.x),
      top: Math.round(point.y + h > window.innerHeight - 8 ? Math.max(8, point.y - h) : point.y),
    });
  }, [open, point]);
  useEffect(() => {
    if (!open || !point) return;
    const away = (e: Event) => {
      if (e.target instanceof Node && list.current?.contains(e.target)) return;
      shut();
    };
    window.addEventListener("scroll", away, true);
    window.addEventListener("wheel", away, { passive: true });
    window.addEventListener("resize", away);
    return () => {
      window.removeEventListener("scroll", away, true);
      window.removeEventListener("wheel", away);
      window.removeEventListener("resize", away);
    };
  }, [open, point]);
  useEffect(() => {
    const area = contextRef?.current;
    if (!area) return;
    let keyAt = 0;
    const at = (x: number, y: number) => {
      back.current = document.activeElement instanceof HTMLElement && document.activeElement !== document.body ? document.activeElement : null;
      setPlace(null);
      setPoint({ x, y });
      setOpen(true);
    };
    const inList = (t: EventTarget | null) => t instanceof Node && !!list.current?.contains(t);
    const onContext = (e: MouseEvent) => {
      if (inList(e.target)) return;
      e.preventDefault();
      if (Date.now() - keyAt < 300) return; // the key already opened it
      if (!e.clientX && !e.clientY) {
        const r = (e.target as Element).getBoundingClientRect(); // from the keyboard
        at(r.left, r.bottom);
      } else at(e.clientX, e.clientY);
    };
    const onKey = (e: KeyboardEvent) => {
      if (!((e.key === "F10" && e.shiftKey) || e.key === "ContextMenu") || inList(e.target)) return;
      e.preventDefault();
      keyAt = Date.now();
      const r = (e.target as Element).getBoundingClientRect();
      at(r.left, r.bottom);
    };
    area.addEventListener("contextmenu", onContext);
    area.addEventListener("keydown", onKey);
    return () => {
      area.removeEventListener("contextmenu", onContext);
      area.removeEventListener("keydown", onKey);
    };
  }, [contextRef]);
  const move = (key: string) => {
    const all = Array.from(list.current?.querySelectorAll<HTMLButtonElement>(".kit-menu__item:not([disabled])") ?? []);
    if (!all.length) return;
    const i = all.indexOf(document.activeElement as HTMLButtonElement);
    all[nextIndex(key, i, all.length)].focus();
  };
  // Back to where the focus was: the element a context menu was opened on, else the menu button.
  const focusBack = () => {
    const to = back.current && document.body.contains(back.current) ? back.current : button.current;
    back.current = null;
    to?.focus();
  };
  // Escape closes and goes back; Tab closes and lets focus move on.
  const close = (key: string) => {
    shut();
    if (key === "Escape") focusBack();
  };
  return (
    <div className={"kit-menu" + (align === "left" ? " kit-menu--left" : "")} ref={wrap}>
      <button
        aria-expanded={open}
        aria-haspopup="menu"
        aria-label={buttonLabel}
        className={buttonLabel ? "kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm" : "kit-btn"}
        onClick={() => {
          setPoint(null);
          setPlace(null);
          setOpen((o) => !o);
        }}
        ref={button}
        type="button"
      >
        {label}
      </button>
      <div
        className="kit-menu__list"
        hidden={!open}
        onKeyDown={(e) => {
          if (MOVE_KEYS.includes(e.key)) {
            e.preventDefault();
            move(e.key);
          } else if (e.key === "Escape" || e.key === "Tab") {
            // Escape closes the menu only: a dialog or side panel around it stays open.
            if (e.key === "Escape") {
              e.preventDefault();
              e.stopPropagation();
            }
            close(e.key);
          }
        }}
        ref={list}
        role="menu"
        style={point ? { position: "fixed", right: "auto", bottom: "auto", left: place?.left ?? point.x, top: place?.top ?? point.y } : undefined}
      >
        {head ? <div className="kit-menu__head">{head}</div> : null}
        {items.map((it) => (
          <div key={it.value} role="none">
            {it.separatorBefore ? <hr className="kit-menu__sep" /> : null}
            <button
              className={"kit-menu__item" + (it.danger ? " kit-menu__item--danger" : "")}
              onClick={() => {
                shut();
                focusBack();
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
