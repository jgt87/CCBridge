/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui action-search-bar (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { useMemo, useState } from "react";

export interface SearchOption {
  value: string;
  label: string;
  meta?: string;
}

/** A search box with a suggestion list; arrow keys and Enter pick one. */
export function SearchBox({ options, onPick, placeholder = "Search", label = "Search" }: { options: SearchOption[]; onPick: (o: SearchOption) => void; placeholder?: string; label?: string }) {
  const [text, setText] = useState("");
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const shown = useMemo(() => {
    const q = text.trim().toLowerCase();
    return q ? options.filter((o) => o.label.toLowerCase().includes(q)) : options;
  }, [text, options]);
  const pick = (o: SearchOption | undefined) => {
    if (!o) return;
    setText(o.label);
    setOpen(false);
    onPick(o);
  };
  const step = (by: number) => setActive((a) => (shown.length ? (a + by + shown.length) % shown.length : -1));
  return (
    <div className="kit-search">
      <input
        aria-label={label}
        className="kit-input"
        onBlur={() => window.setTimeout(() => setOpen(false), 120)}
        onChange={(e) => {
          setText(e.target.value);
          setOpen(true);
          setActive(-1);
        }}
        onFocus={() => setOpen(true)}
        onKeyDown={(e) => {
          if (e.key === "ArrowDown") {
            e.preventDefault();
            step(1);
          } else if (e.key === "ArrowUp") {
            e.preventDefault();
            step(-1);
          } else if (e.key === "Enter" && active >= 0) {
            e.preventDefault();
            pick(shown[active]);
          } else if (e.key === "Escape") setOpen(false);
        }}
        placeholder={placeholder}
        value={text}
      />
      {open && shown.length > 0 && (
        <ul className="kit-search__list">
          {shown.map((o, i) => (
            <li
              className={`kit-search__item${i === active ? " is-active" : ""}`}
              key={o.value}
              onMouseDown={(e) => {
                e.preventDefault();
                pick(o);
              }}
            >
              <span>{o.label}</span>
              {o.meta && <span className="kit-search__meta">{o.meta}</span>}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
