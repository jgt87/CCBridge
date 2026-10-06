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
  return { group, style: { width: box.width, transform: `translateX(${box.left}px)` } };
}

/** Tabs with a sliding underline. */
export function Tabs({ tabs, value, onChange, label }: { tabs: string[]; value: number; onChange: (i: number) => void; label: string }) {
  const { group, style } = useIndicator(value);
  return (
    <div aria-label={label} className="kit-tabs kit-tabs--animated" ref={group} role="tablist">
      {tabs.map((t, i) => (
        <button aria-selected={i === value} className="kit-tab" key={t} onClick={() => onChange(i)} role="tab" type="button">
          {t}
        </button>
      ))}
      <span aria-hidden="true" className="kit-tabs__indicator" style={style} />
    </div>
  );
}

/** A segmented choice with a sliding background. */
export function Segmented({ options, value, onChange, label }: { options: string[]; value: number; onChange: (i: number) => void; label: string }) {
  const { group, style } = useIndicator(value);
  return (
    <div aria-label={label} className="kit-segmented kit-segmented--animated" ref={group} role="group">
      {options.map((o, i) => (
        <button aria-pressed={i === value} key={o} onClick={() => onChange(i)} type="button">
          {o}
        </button>
      ))}
      <span aria-hidden="true" className="kit-segmented__indicator" style={style} />
    </div>
  );
}
