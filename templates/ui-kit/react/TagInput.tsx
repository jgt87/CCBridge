/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { useId, useRef, useState } from "react";

/** Tags typed in a field: Enter or a comma adds one, Backspace in the empty field removes the last. */
export function TagInput({ value, onChange, label, suggestions }: { value: string[]; onChange: (values: string[]) => void; label: string; suggestions?: string[] }) {
  const [text, setText] = useState("");
  const [said, setSaid] = useState("");
  const input = useRef<HTMLInputElement>(null);
  const listId = useId();
  const add = (t: string) => {
    const v = t.replace(/,/g, " ").trim();
    if (v && value.includes(v)) {
      // Refused with a reason; the text stays in the field to change it.
      setSaid(v + " is already added");
      return;
    }
    if (v) {
      onChange([...value, v]);
      setSaid("Added " + v);
    }
    setText("");
  };
  // A pasted list (commas or new lines) becomes one tag per item; duplicates are left out.
  const addMany = (parts: string[]) => {
    const next = [...value];
    for (const p of parts.map((x) => x.trim()).filter(Boolean)) if (!next.includes(p)) next.push(p);
    const added = next.slice(value.length);
    if (added.length) {
      onChange(next);
      setSaid("Added " + added.join(", "));
    }
    setText("");
  };
  return (
    <div
      aria-label={label}
      className="kit-tags"
      onClick={(e) => {
        if (e.target === e.currentTarget) input.current?.focus();
      }}
      role="group"
    >
      {value.map((v) => (
        <span className="kit-tags__tag" key={v}>
          {v}
          <button
            aria-label={"Remove " + v}
            className="kit-tags__remove"
            onClick={() => {
              onChange(value.filter((x) => x !== v));
              setSaid("Removed " + v);
              input.current?.focus();
            }}
            type="button"
          >
            {"\u00d7"}
          </button>
        </span>
      ))}
      <input
        aria-label={label}
        className="kit-tags__input"
        list={suggestions?.length ? listId : undefined}
        onChange={(e) => setText(e.target.value)}
        onPaste={(e) => {
          const pasted = e.clipboardData.getData("text");
          if (!/[,\r\n]/.test(pasted)) return; // one word: the field takes it as typed
          e.preventDefault();
          addMany((text + pasted).split(/[,\r\n]+/));
        }}
        onKeyDown={(e) => {
          if (e.nativeEvent.isComposing) return; // a key that ends an IME composition is not Enter
          if (e.key === "Enter" || e.key === ",") {
            e.preventDefault();
            add(text);
          } else if (e.key === "Backspace" && !text && value.length) {
            onChange(value.slice(0, -1));
            setSaid("Removed " + value[value.length - 1]);
          }
        }}
        ref={input}
        type="text"
        value={text}
      />
      {suggestions?.length ? (
        <datalist id={listId}>
          {suggestions.map((s) => (
            <option key={s} value={s} />
          ))}
        </datalist>
      ) : null}
      {/* Adds and removes, read out by screen readers. */}
      <span aria-live="polite" className="kit-sr-only">
        {said}
      </span>
    </div>
  );
}
