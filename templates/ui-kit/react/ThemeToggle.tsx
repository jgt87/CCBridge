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
// The computer switching between light and dark (while no choice is on <html>) is a theme change too:
// one "kit:theme" on the document (as kit.js sends), so charts and canvas code read their colours again.
if (typeof window !== "undefined" && window.matchMedia && !(window as { kitSystemThemeEvent?: boolean }).kitSystemThemeEvent) {
  (window as { kitSystemThemeEvent?: boolean }).kitSystemThemeEvent = true;
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change", () => {
    const t = document.documentElement.getAttribute("data-theme");
    if (t === "dark" || t === "light") return;
    document.dispatchEvent(new CustomEvent("kit:theme", { detail: { theme: currentTheme() } }));
  });
}

/** The light/dark button for the band header: follows the computer until clicked, keeps the choice; its icon and label say what a click does. */
export function ThemeToggle({ onChange, disabled }: { onChange?: (theme: Theme) => void; disabled?: boolean }) {
  const [theme, setTheme] = useState<Theme>(currentTheme);
  useEffect(() => {
    const follow = () => setTheme(currentTheme());
    // Every theme button on the page says what a click does now, not only the one pressed (kit.js's too).
    document.addEventListener("kit:theme", follow);
    const mq = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
    mq?.addEventListener?.("change", follow);
    return () => {
      document.removeEventListener("kit:theme", follow);
      mq?.removeEventListener?.("change", follow);
    };
  }, []);
  const label = theme === "dark" ? "Switch to the light theme" : "Switch to the dark theme";
  return (
    <Tooltip text={label}>
      <button
        aria-disabled={disabled || undefined}
        aria-label={label}
        className="kit-btn kit-btn--ghost kit-btn--icon"
        onClick={(e) => {
          if (disabled) return;
          const next: Theme = currentTheme() === "dark" ? "light" : "dark";
          // The whole page changes at once: kit.css stops its transitions while this is set (two frames).
          const html = document.documentElement;
          html.setAttribute("data-kit-theme-switching", "");
          const raf = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : (f: () => void) => window.setTimeout(f, 16);
          raf(() => raf(() => html.removeAttribute("data-kit-theme-switching")));
          html.setAttribute("data-theme", next);
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
