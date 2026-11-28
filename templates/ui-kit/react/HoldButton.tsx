/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from an open-source component library (MIT licence; see ../LICENSE-kokonutui.txt).
 */
import { type KeyboardEvent, type PointerEvent, useEffect, useId, useRef, useState } from "react";

const isHoldKey = (k: string) => k === " " || k === "Enter";

/**
 * Press and hold to confirm a destructive action. disabled keeps the button focusable (aria-disabled:
 * it looks unavailable and ignores presses), as does busy (aria-busy). doneLabel is the confirmed word
 * ("Deleted"), shown in place of the label and announced until the next hold.
 */
export function HoldButton({ label, holdMs = 1500, onConfirm, disabled, busy, doneLabel }: { label: string; holdMs?: number; onConfirm: () => void; disabled?: boolean; busy?: boolean; doneLabel?: string }) {
  const [holding, setHolding] = useState(false);
  const [done, setDone] = useState(false);
  const timer = useRef<number | null>(null);
  const helpId = useId();
  const off = !!disabled || !!busy;
  const stop = () => {
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = null;
    setHolding(false); // let go early: the fill empties quickly (kit.css)
  };
  const start = () => {
    if (off || timer.current !== null) return;
    setDone(false);
    setHolding(true);
    timer.current = window.setTimeout(() => {
      timer.current = null;
      setHolding(false);
      setDone(true); // the fill stays full until the next hold
      onConfirm();
    }, holdMs);
  };
  useEffect(() => stop, []);
  const onKeyDown = (e: KeyboardEvent<HTMLButtonElement>) => {
    if (!isHoldKey(e.key)) return;
    e.preventDefault(); // no native click: the hold is the action
    if (e.repeat) return; // a held key repeats: it does not start again
    start();
  };
  const onKeyUp = (e: KeyboardEvent<HTMLButtonElement>) => {
    if (isHoldKey(e.key)) e.preventDefault(); // Space's keyup would click
    stop();
  };
  const onPointerDown = (e: PointerEvent<HTMLButtonElement>) => {
    if (e.button !== 0) return; // only the primary button holds (not a right or middle press)
    start();
  };
  // Described as a hold (hidden text, read through aria-describedby) and announced when done; both sit
  // beside the button, so its name stays its label.
  return (
    <>
      <button
        aria-busy={busy || undefined}
        aria-describedby={helpId}
        aria-disabled={disabled || undefined}
        className={`kit-btn kit-btn--hold${holding ? " is-holding" : ""}${done ? " is-done" : ""}`}
        onBlur={stop}
        onClick={(e) => e.preventDefault()}
        onKeyDown={onKeyDown}
        onKeyUp={onKeyUp}
        onPointerCancel={stop}
        onPointerDown={onPointerDown}
        onPointerLeave={stop}
        onPointerUp={stop}
        style={{ ["--kit-hold-ms" as string]: `${holdMs}ms` }}
        type="button"
      >
        {holding ? "Keep holding..." : done && doneLabel ? doneLabel : label}
      </button>
      <span hidden id={helpId}>
        Press and hold to confirm
      </span>
      <span aria-live="polite" className="kit-sr-only">
        {done ? doneLabel || label + ": confirmed" : ""}
      </span>
    </>
  );
}
