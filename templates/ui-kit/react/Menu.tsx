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
  /** Unavailable: stays in place and in the arrow-key order (aria-disabled), but cannot be picked. */
  disabled?: boolean;
}

const MOVE_KEYS = ["ArrowDown", "ArrowUp", "Home", "End"];

// Type-ahead in menus and trees: a printable key moves to the next item whose text starts with what
// was typed in the last 600 ms (one letter again steps through the items with that letter).
let typed = "";
let typedAt = 0;
function isTypeaheadKey(e: { key: string; ctrlKey: boolean; metaKey: boolean; altKey: boolean }) {
  return e.key.length === 1 && e.key !== " " && !e.ctrlKey && !e.metaKey && !e.altKey;
}
function typeahead<T extends Element>(items: T[], current: Element | null, key: string): T | null {
  const now = Date.now();
  const k = key.toLowerCase();
  typed = now - typedAt > 600 ? k : typed + k;
  typedAt = now;
  const at = items.indexOf(current as T);
  const order = items.slice(at + 1).concat(items.slice(0, at + 1));
  const starts = (want: string) => (it: T) => (it.textContent || "").trim().toLowerCase().startsWith(want);
  return order.find(starts(typed)) || (typed.length > 1 ? null : order.find(starts(k))) || null;
}

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
  // ArrowUp on the button opens the menu on its last item; everything else on the first.
  const startAt = useRef<"first" | "last">("first");
  useEffect(() => {
    if (!open) return;
    const rows = list.current?.querySelectorAll<HTMLButtonElement>(".kit-menu__item:not([disabled])");
    (startAt.current === "last" && rows?.length ? rows[rows.length - 1] : rows?.[0])?.focus();
    startAt.current = "first";
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
  // Every item, aria-disabled ones included (they keep their place); natively disabled ones are left out.
  const menuItems = () => Array.from(list.current?.querySelectorAll<HTMLButtonElement>(".kit-menu__item:not([disabled])") ?? []);
  const move = (key: string) => {
    const all = menuItems();
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
        onKeyDown={(e) => {
          // ArrowDown or ArrowUp on the button opens the menu on its first or last item (Enter and Space click).
          if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
          e.preventDefault();
          if (open) {
            move(e.key === "ArrowDown" ? "Home" : "End");
            return;
          }
          startAt.current = e.key === "ArrowUp" ? "last" : "first";
          setPoint(null);
          setPlace(null);
          setOpen(true);
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
          } else if (isTypeaheadKey(e)) {
            const to = typeahead(menuItems(), document.activeElement, e.key);
            if (to) {
              e.preventDefault();
              to.focus();
            }
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
              aria-disabled={it.disabled || undefined}
              className={"kit-menu__item" + (it.danger ? " kit-menu__item--danger" : "")}
              onClick={() => {
                if (it.disabled) return; // stays open: nothing was picked
                shut();
                focusBack();
                onPick(it.value);
              }}
              role="menuitem"
              tabIndex={-1}
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
