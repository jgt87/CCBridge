/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui hold-button (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { useEffect, useRef, useState } from "react";

/** Press and hold to confirm a destructive action. */
export function HoldButton({ label, holdMs = 1500, onConfirm, disabled }: { label: string; holdMs?: number; onConfirm: () => void; disabled?: boolean }) {
  const [holding, setHolding] = useState(false);
  const [done, setDone] = useState(false);
  const timer = useRef<number | null>(null);
  const stop = () => {
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = null;
    setHolding(false);
  };
  const start = () => {
    if (disabled || timer.current !== null) return;
    setDone(false);
    setHolding(true);
    timer.current = window.setTimeout(() => {
      timer.current = null;
      setHolding(false);
      setDone(true);
      onConfirm();
    }, holdMs);
  };
  useEffect(() => stop, []);
  return (
    <button
      className={`kit-btn kit-btn--hold${holding ? " is-holding" : ""}${done ? " is-done" : ""}`}
      disabled={disabled}
      onBlur={stop}
      onKeyDown={(e) => {
        if (e.key === " " || e.key === "Enter") {
          e.preventDefault();
          start();
        }
      }}
      onKeyUp={stop}
      onPointerCancel={stop}
      onPointerDown={start}
      onPointerLeave={stop}
      onPointerUp={stop}
      style={{ ["--kit-hold-ms" as string]: `${holdMs}ms` }}
      type="button"
    >
      {holding ? "Keep holding..." : label}
    </button>
  );
}
