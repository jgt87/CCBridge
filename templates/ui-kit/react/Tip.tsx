/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { useId, useState } from "react";

/** An info tip next to a figure or column name: the question as its label, the answer on hover and focus. */
export function Tip({ label, text }: { label: string; text: string }) {
  const [shown, setShown] = useState(false);
  const id = useId();
  return (
    <button
      aria-describedby={id}
      aria-label={label}
      className="kit-tip"
      onBlur={() => setShown(false)}
      onClick={(e) => {
        e.preventDefault();
        setShown((s) => !s);
      }}
      onFocus={() => setShown(true)}
      onKeyDown={(e) => {
        if (e.key === "Escape") setShown(false);
      }}
      onMouseEnter={() => setShown(true)}
      onMouseLeave={(e) => {
        if (document.activeElement !== e.currentTarget) setShown(false);
      }}
      type="button"
    >
      <span className="kit-tip__bubble" hidden={!shown} id={id} role="tooltip">
        {text}
      </span>
    </button>
  );
}
