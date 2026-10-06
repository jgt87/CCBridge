/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui command-button (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { useEffect } from "react";

/** A button that shows its keyboard shortcut (for example "Ctrl+K") and also runs from it. */
export function CommandButton({ label, keys, onRun }: { label: string; keys: string; onRun: () => void }) {
  useEffect(() => {
    const parts = keys.toLowerCase().split("+");
    const key = parts[parts.length - 1];
    const ctrl = parts.includes("ctrl");
    const onKey = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() === key && e.ctrlKey === ctrl) {
        e.preventDefault();
        onRun();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [keys, onRun]);
  return (
    <button className="kit-btn" onClick={onRun} type="button">
      {label}
      <kbd className="kit-kbd">{keys}</kbd>
    </button>
  );
}
