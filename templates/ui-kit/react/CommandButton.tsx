/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui command-button (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { useEffect } from "react";

/**
 * A button that shows its keyboard shortcut (for example "Ctrl+K") and also runs from it. While its
 * action runs, busy shows the kit's spinner in it (aria-busy) and says busyText to screen readers in a
 * status line beside it (the spinner alone says nothing).
 */
export function CommandButton({ label, keys, onRun, busy = false, busyText = "Working" }: { label: string; keys: string; onRun: () => void; busy?: boolean; busyText?: string }) {
  useEffect(() => {
    const parts = keys.toLowerCase().split("+");
    const key = parts[parts.length - 1];
    const ctrl = parts.includes("ctrl");
    const onKey = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() === key && e.ctrlKey === ctrl) {
        e.preventDefault();
        if (!busy) onRun();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [keys, onRun, busy]);
  return (
    <>
      <button aria-busy={busy || undefined} className="kit-btn" onClick={onRun} type="button">
        {label}
        <kbd className="kit-kbd">{keys}</kbd>
      </button>
      <span className="kit-sr-only" role="status">
        {busy ? busyText : ""}
      </span>
    </>
  );
}
