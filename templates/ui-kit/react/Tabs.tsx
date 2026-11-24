/**
 * UI kit components for React projects: render the kit's markup (styles/kit/kit.css), need only React.
 * Adapted from kokonutui smooth-tab (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { useLayoutEffect, useRef, useState } from "react";

/** Where the selected button is, for the sliding indicator. */
function useIndicator(index: number) {
  const group = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState({ left: 0, width: 0 });
  useLayoutEffect(() => {
    const measure = () => {
      const el = group.current?.querySelectorAll<HTMLButtonElement>("button")[index];
      if (el) setBox({ left: el.offsetLeft, width: el.offsetWidth });
    };
    measure();
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, [index]);
  return {
    group,
    style: { width: box.width, transform: `translateX(${box.left}px)` },
    // The tab underline is 100px wide in kit.css and scaled to the tab: it moves by transform, never by width.
    lineStyle: { transform: `translateX(${box.left}px) scaleX(${box.width / 100})` },
  };
}

/**
 * Tabs with a sliding underline. The arrow keys, Home and End move between them (one tab stop).
 * disabled lists the indexes of unavailable tabs: they keep their place and focus (aria-disabled) but are never selected.
 */
export function Tabs({ tabs, value, onChange, label, disabled = [] }: { tabs: string[]; value: number; onChange: (i: number) => void; label: string; disabled?: number[] }) {
  const { group, lineStyle } = useIndicator(value);
  const onKey = (e: React.KeyboardEvent<HTMLDivElement>) => {
    // From the selected tab, or from an unavailable one the arrows reached (it has focus but is not selected).
    const focused = Array.from(group.current?.querySelectorAll<HTMLButtonElement>("button.kit-tab") ?? []).indexOf(document.activeElement as HTMLButtonElement);
    const from = disabled.includes(focused) ? focused : value;
    const step = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
    const next = step ? (from + step + tabs.length) % tabs.length : e.key === "Home" ? 0 : e.key === "End" ? tabs.length - 1 : -1;
    if (next < 0) return;
    e.preventDefault();
    if (!disabled.includes(next)) onChange(next);
    group.current?.querySelectorAll<HTMLButtonElement>("button")[next]?.focus();
  };
  return (
    <div aria-label={label} className="kit-tabs kit-tabs--animated" onKeyDown={onKey} ref={group} role="tablist">
      {tabs.map((t, i) => (
        <button aria-disabled={disabled.includes(i) || undefined} aria-selected={i === value} className="kit-tab" key={t} onClick={() => !disabled.includes(i) && onChange(i)} role="tab" tabIndex={i === value ? 0 : -1} type="button">
          {t}
        </button>
      ))}
      <span aria-hidden="true" className="kit-tabs__indicator" style={lineStyle} />
    </div>
  );
}

/** A segmented choice with a sliding background. disabled lists unavailable options (aria-disabled: focusable, never chosen). */
export function Segmented({ options, value, onChange, label, disabled = [] }: { options: string[]; value: number; onChange: (i: number) => void; label: string; disabled?: number[] }) {
  const { group, style } = useIndicator(value);
  return (
    <div aria-label={label} className="kit-segmented kit-segmented--animated" ref={group} role="group">
      {options.map((o, i) => (
        <button aria-disabled={disabled.includes(i) || undefined} aria-pressed={i === value} key={o} onClick={() => !disabled.includes(i) && onChange(i)} type="button">
          {o}
        </button>
      ))}
      <span aria-hidden="true" className="kit-segmented__indicator" style={style} />
    </div>
  );
}
