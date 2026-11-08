/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * The same light/dark switch as kit.js's data-kit-theme: the same storage key, data-theme on <html>.
 */
import { useEffect, useState } from "react";
import { Icon } from "./Icon";
import { Tooltip } from "./Tooltip";

export type Theme = "light" | "dark";
const KEY = "kit-theme";

function saved(): string | null {
  try {
    return localStorage.getItem(KEY);
  } catch {
    return null; // blocked storage: follow the computer
  }
}
function systemDark() {
  return typeof window !== "undefined" && !!window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
}
/** The theme the page shows now: the choice on <html>, else the computer's. */
export function currentTheme(): Theme {
  const t = typeof document !== "undefined" ? document.documentElement.getAttribute("data-theme") : null;
  if (t === "dark" || t === "light") return t;
  return systemDark() ? "dark" : "light";
}
// A choice made earlier applies as soon as the module loads, before the first paint of the app.
if (typeof document !== "undefined") {
  const s = saved();
  if (s === "dark" || s === "light") document.documentElement.setAttribute("data-theme", s);
}

/** The light/dark button for the band header: follows the computer until clicked, keeps the choice; its icon and label say what a click does. */
export function ThemeToggle({ onChange }: { onChange?: (theme: Theme) => void }) {
  const [theme, setTheme] = useState<Theme>(currentTheme);
  useEffect(() => {
    if (!window.matchMedia) return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const follow = () => setTheme(currentTheme());
    mq.addEventListener?.("change", follow);
    return () => mq.removeEventListener?.("change", follow);
  }, []);
  const label = theme === "dark" ? "Switch to the light theme" : "Switch to the dark theme";
  return (
    <Tooltip text={label}>
      <button
        aria-label={label}
        className="kit-btn kit-btn--ghost kit-btn--icon"
        onClick={(e) => {
          const next: Theme = currentTheme() === "dark" ? "light" : "dark";
          document.documentElement.setAttribute("data-theme", next);
          try {
            localStorage.setItem(KEY, next);
          } catch {
            /* not kept: private window or blocked storage */
          }
          setTheme(next);
          // Charts and canvas code read their colours again on kit:theme, as with kit.js.
          e.currentTarget.dispatchEvent(new CustomEvent("kit:theme", { bubbles: true, detail: { theme: next } }));
          onChange?.(next);
        }}
        type="button"
      >
        <Icon name={theme === "dark" ? "sun" : "moon"} />
      </button>
    </Tooltip>
  );
}
