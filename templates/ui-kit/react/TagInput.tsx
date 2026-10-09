/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { useId, useRef, useState } from "react";

/** Tags typed in a field: Enter or a comma adds one, Backspace in the empty field removes the last. */
export function TagInput({ value, onChange, label, suggestions }: { value: string[]; onChange: (values: string[]) => void; label: string; suggestions?: string[] }) {
  const [text, setText] = useState("");
  const input = useRef<HTMLInputElement>(null);
  const listId = useId();
  const add = (t: string) => {
    const v = t.replace(/,/g, " ").trim();
    if (v && !value.includes(v)) onChange([...value, v]);
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
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === ",") {
            e.preventDefault();
            add(text);
          } else if (e.key === "Backspace" && !text && value.length) onChange(value.slice(0, -1));
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
    </div>
  );
}
