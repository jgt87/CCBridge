/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";

// A tip opens after the pointer rests on it a moment, at once on focus, and at once next to a tip that just closed.
const DELAY = 500;
const WARM = 600;
let warmUntil = 0;

/** An info tip next to a figure or column name: the question as its label, the answer on hover and focus. */
export function Tip({ label, text }: { label: string; text: string }) {
  const [shown, setShown] = useState(false);
  const [place, setPlace] = useState("");
  const id = useId();
  const button = useRef<HTMLButtonElement>(null);
  const bubble = useRef<HTMLSpanElement>(null);
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
    setPlace("");
    setShown((s) => {
      if (s) warmUntil = Date.now() + WARM;
      return false;
    });
  };
  // Kept on the screen: to the left or right edge when it would run off, below its button when there is no room above.
  useLayoutEffect(() => {
    if (!shown || !bubble.current) return;
    const r = bubble.current.getBoundingClientRect();
    setPlace((r.left < 8 ? " is-left" : r.right > window.innerWidth - 8 ? " is-right" : "") + (r.top < 8 ? " is-below" : ""));
  }, [shown]);
  // Closes on scroll, wheel or a press elsewhere.
  useEffect(() => {
    if (!shown) return;
    const away = (e: Event) => {
      if (e.type === "pointerdown" && button.current?.contains(e.target as Node)) return;
      hide();
    };
    window.addEventListener("scroll", away, true);
    window.addEventListener("wheel", away, { passive: true });
    document.addEventListener("pointerdown", away, true);
    return () => {
      window.removeEventListener("scroll", away, true);
      window.removeEventListener("wheel", away);
      document.removeEventListener("pointerdown", away, true);
    };
  }, [shown]);
  useEffect(() => cancel, []);
  return (
    <button
      aria-describedby={id}
      aria-label={label}
      className="kit-tip"
      onBlur={hide}
      onClick={(e) => {
        e.preventDefault();
        if (shown) hide();
        else show();
      }}
      onFocus={show}
      onKeyDown={(e) => {
        if (e.key === "Escape" && shown) {
          e.preventDefault(); // the tip only: a dialog or side panel around it stays open
          e.stopPropagation();
          hide();
        }
      }}
      onMouseEnter={() => {
        if (shown || wait.current !== null) return;
        if (Date.now() < warmUntil) show();
        else wait.current = window.setTimeout(show, DELAY);
      }}
      onMouseLeave={(e) => {
        if (document.activeElement !== e.currentTarget) hide();
      }}
      ref={button}
      type="button"
    >
      <span className={"kit-tip__bubble" + (shown ? place : "")} hidden={!shown} id={id} ref={bubble} role="tooltip">
        {text}
      </span>
    </button>
  );
}
