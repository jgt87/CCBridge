/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { cloneElement, type FocusEvent, type HTMLAttributes, type KeyboardEvent, type MouseEvent, type ReactElement, type TouchEvent, useEffect, useId, useLayoutEffect, useRef, useState } from "react";

// Like the info tip: it opens after the pointer rests a moment, at once on keyboard focus, and at once next to a tooltip that just closed.
const DELAY = 500;
const WARM = 600;
let warmUntil = 0;
let pressAt = 0;
let touchAt = 0;

type Trigger = ReactElement<HTMLAttributes<HTMLElement>>;

/**
 * A short label for an icon button or a cut-off text, instead of title: <Tooltip text="Edit"><button aria-label="Edit" ...></Tooltip>.
 * Never on touch; above the element (below when there is no room), kept inside the window.
 */
export function Tooltip({ text, children }: { text: string; children: Trigger }) {
  const [shown, setShown] = useState(false);
  const [place, setPlace] = useState<{ left: number; top: number } | null>(null);
  const id = useId();
  const anchor = useRef<HTMLElement | null>(null);
  const bubble = useRef<HTMLDivElement>(null);
  const wait = useRef<number | null>(null);
  const cancel = () => {
    if (wait.current !== null) window.clearTimeout(wait.current);
    wait.current = null;
  };
  const show = () => {
    cancel();
    setShown(true);
  };
  const hide = () => {
    cancel();
    setPlace(null);
    setShown((s) => {
      if (s) warmUntil = Date.now() + WARM;
      return false;
    });
  };
  // Measured each time it opens: centred above the element, below it near the top edge, 8px from the window's sides.
  useLayoutEffect(() => {
    if (!shown || !anchor.current || !bubble.current) return;
    const r = anchor.current.getBoundingClientRect();
    const b = bubble.current.getBoundingClientRect();
    const left = Math.max(8, Math.min(r.left + r.width / 2 - b.width / 2, window.innerWidth - 8 - b.width));
    const top = r.top - 6 - b.height < 8 ? r.bottom + 6 : r.top - 6 - b.height;
    setPlace({ left: Math.round(left), top: Math.round(top) });
  }, [shown, text]);
  // Gone on scroll, wheel, resize or a press anywhere.
  useEffect(() => {
    if (!shown) return;
    const away = () => hide();
    window.addEventListener("scroll", away, true);
    window.addEventListener("wheel", away, { passive: true });
    window.addEventListener("resize", away);
    document.addEventListener("pointerdown", away, true);
    return () => {
      window.removeEventListener("scroll", away, true);
      window.removeEventListener("wheel", away);
      window.removeEventListener("resize", away);
      document.removeEventListener("pointerdown", away, true);
    };
  }, [shown]);
  useEffect(() => cancel, []);
  const own = children.props;
  const describe = shown && text !== own["aria-label"];
  return (
    <>
      {cloneElement(children, {
        "aria-describedby": describe ? id : own["aria-describedby"],
        onBlur: (e: FocusEvent<HTMLElement>) => {
          own.onBlur?.(e);
          hide();
        },
        onFocus: (e: FocusEvent<HTMLElement>) => {
          own.onFocus?.(e);
          anchor.current = e.currentTarget;
          if (Date.now() - pressAt > 600) show(); // keyboard focus, not the focus a click gives
        },
        onKeyDown: (e: KeyboardEvent<HTMLElement>) => {
          own.onKeyDown?.(e);
          if (e.key === "Escape" && shown) {
            e.preventDefault(); // the tooltip only: a dialog or side panel around it stays open
            e.stopPropagation();
            hide();
          }
        },
        onMouseDown: (e: MouseEvent<HTMLElement>) => {
          own.onMouseDown?.(e);
          pressAt = Date.now();
        },
        onMouseEnter: (e: MouseEvent<HTMLElement>) => {
          own.onMouseEnter?.(e);
          anchor.current = e.currentTarget;
          if (shown || wait.current !== null || Date.now() - touchAt < 1000) return; // the mouse events a tap makes
          if (Date.now() < warmUntil) show();
          else wait.current = window.setTimeout(show, DELAY);
        },
        onMouseLeave: (e: MouseEvent<HTMLElement>) => {
          own.onMouseLeave?.(e);
          if (document.activeElement !== e.currentTarget) hide();
        },
        onTouchStart: (e: TouchEvent<HTMLElement>) => {
          own.onTouchStart?.(e);
          touchAt = pressAt = Date.now();
        },
      })}
      {shown ? (
        <div className="kit-tooltip" id={id} ref={bubble} role="tooltip" style={place ? { left: place.left, top: place.top } : { visibility: "hidden" }}>
          {text}
        </div>
      ) : null}
    </>
  );
}
