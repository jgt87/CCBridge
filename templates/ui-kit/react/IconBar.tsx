/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui toolbar (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { type ReactNode, useRef } from "react";

export interface IconBarItem {
  value: string;
  label: string;
  icon: ReactNode;
}

/** A row of icon buttons (a view switch, tools); the pressed one shows its label; arrow keys move between them. */
export function IconBar({ label, items, value, multiple = false, onChange }: { label: string; items: IconBarItem[]; value: string[]; multiple?: boolean; onChange: (values: string[]) => void }) {
  const bar = useRef<HTMLDivElement>(null);
  const press = (v: string) => {
    if (!multiple) onChange([v]);
    else onChange(value.includes(v) ? value.filter((x) => x !== v) : [...value, v]);
  };
  return (
    <div
      aria-label={label}
      className="kit-iconbar"
      onKeyDown={(e) => {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
        const all = Array.from(bar.current?.querySelectorAll<HTMLButtonElement>(".kit-iconbar__item") ?? []);
        const i = all.indexOf(document.activeElement as HTMLButtonElement);
        if (i < 0) return;
        e.preventDefault();
        all[(i + (e.key === "ArrowRight" ? 1 : -1) + all.length) % all.length].focus();
      }}
      ref={bar}
      role="toolbar"
    >
      {items.map((it) => (
        <button aria-label={it.label} aria-pressed={value.includes(it.value)} className="kit-iconbar__item" key={it.value} onClick={() => press(it.value)} type="button">
          <span aria-hidden="true">{it.icon}</span>
          <span className="kit-iconbar__label">{it.label}</span>
        </button>
      ))}
    </div>
  );
}
