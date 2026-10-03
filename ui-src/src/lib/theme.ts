// Light / dark / system theme, chosen in Settings and kept in this browser. Applied before the
// page draws (main.tsx), so there is no flash of the other theme. "system" follows Windows, also
// when it switches while the app is open. Pages that draw in theme colours (Mermaid diagrams)
// listen for the "ccb-theme" event to redraw.

export type ThemeChoice = "system" | "light" | "dark";

const KEY = "ccb.theme";
const media = () => window.matchMedia("(prefers-color-scheme: light)");

export function getThemeChoice(): ThemeChoice {
  try {
    const v = localStorage.getItem(KEY);
    return v === "light" || v === "dark" ? v : "system";
  } catch {
    return "system";
  }
}

/** Dark unless light is chosen, or "system" and Windows prefers light (as before this setting). */
function isDark(choice: ThemeChoice) {
  return choice === "dark" || (choice === "system" && !media().matches);
}

function apply(choice: ThemeChoice) {
  const dark = isDark(choice);
  const root = document.documentElement;
  if (root.classList.contains("dark") === dark) return;
  root.classList.toggle("dark", dark);
  window.dispatchEvent(new Event("ccb-theme"));
}

export function setThemeChoice(choice: ThemeChoice) {
  try {
    if (choice === "system") localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, choice);
  } catch {
    /* storage blocked: applies until the page reloads */
  }
  apply(choice);
}

/** Once at start: apply the choice, and follow Windows while the choice is "system". */
export function initTheme() {
  apply(getThemeChoice());
  media().addEventListener("change", () => {
    if (getThemeChoice() === "system") apply("system");
  });
}
