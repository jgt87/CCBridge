/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * The command palette of kit.js's data-kit-palette: a kit-dialog with a search field and a kit-search list.
 */
import { useEffect, useId, useMemo, useRef, useState } from "react";
import { Icon } from "./Icon";

export interface Command {
  value: string;
  label: string;
  meta?: string;
  shortcut?: string;
}

/**
 * Ctrl+K (Cmd+K) opens it from anywhere but a field (or open/onOpenChange from a button). Typing filters,
 * the arrow keys move, Enter runs the command; Escape clears the text first, then closes, and the focus
 * goes back where it was. Every command should also be on a visible button or menu.
 */
export function CommandPalette({ commands, onRun, label = "Commands", placeholder = "Type a command", empty = "No commands match", open, onOpenChange }: { commands: Command[]; onRun: (c: Command) => void; label?: string; placeholder?: string; empty?: string; open?: boolean; onOpenChange?: (open: boolean) => void }) {
  const [own, setOwn] = useState(false);
  const isOpen = open ?? own;
  const [text, setText] = useState("");
  const [active, setActive] = useState(0);
  const [said, setSaid] = useState("");
  const dialog = useRef<HTMLDialogElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const back = useRef<HTMLElement | null>(null);
  const listId = useId();
  const shown = useMemo(() => {
    const q = text.trim().toLowerCase();
    return q ? commands.filter((c) => (c.label + " " + (c.meta ?? "")).toLowerCase().includes(q)) : commands;
  }, [text, commands]);
  const setOpen = (o: boolean) => {
    if (o) {
      back.current = document.activeElement as HTMLElement | null;
      setText("");
      setActive(0);
    }
    if (open === undefined) setOwn(o);
    onOpenChange?.(o);
  };
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (!(e.ctrlKey || e.metaKey) || e.altKey || e.shiftKey || e.key.toLowerCase() !== "k") return;
      if (isOpen) {
        e.preventDefault();
        setOpen(false);
        return;
      }
      if ((e.target as Element | null)?.closest?.("input, textarea, select, [contenteditable]")) return; // a field keeps its own keys
      e.preventDefault();
      setOpen(true);
    };
    document.addEventListener("keydown", key);
    return () => document.removeEventListener("keydown", key);
  });
  useEffect(() => {
    const d = dialog.current;
    if (!d) return;
    if (isOpen && !d.open) {
      if (d.showModal) d.showModal();
      else d.setAttribute("open", "");
      input.current?.focus();
    } else if (!isOpen && d.open) {
      if (d.close) d.close();
      else d.removeAttribute("open");
      if (back.current && document.body.contains(back.current)) back.current.focus();
      back.current = null;
    }
  }, [isOpen]);
  const run = (c: Command | undefined) => {
    if (!c) return;
    setOpen(false);
    onRun(c);
  };
  const at = shown.length ? Math.min(active, shown.length - 1) : -1;
  return (
    <dialog
      aria-label={label}
      className="kit-dialog kit-palette"
      onCancel={(e) => {
        e.preventDefault();
        setOpen(false);
      }}
      ref={dialog}
    >
      <div className="kit-input-icon">
        <Icon className="kit-icon" name="search" />
        <input
          aria-activedescendant={at >= 0 ? listId + "-" + at : undefined}
          aria-autocomplete="list"
          aria-controls={listId}
          aria-expanded={shown.length > 0}
          aria-label={label}
          autoComplete="off"
          className="kit-input"
          onChange={(e) => {
            const q = e.target.value.trim().toLowerCase();
            const n = q ? commands.filter((c) => (c.label + " " + (c.meta ?? "")).toLowerCase().includes(q)).length : commands.length;
            setText(e.target.value);
            setActive(0);
            setSaid(n === 1 ? "1 result" : n + " results");
          }}
          onKeyDown={(e) => {
            if (e.nativeEvent.isComposing) return; // Enter that ends a composition (IME) runs nothing
            if (e.key === "ArrowDown" || e.key === "ArrowUp") {
              e.preventDefault();
              if (shown.length) setActive((at + (e.key === "ArrowDown" ? 1 : -1) + shown.length) % shown.length);
            } else if (e.key === "Enter" && at >= 0) {
              e.preventDefault();
              run(shown[at]);
            } else if (e.key === "Escape" && text) {
              e.preventDefault(); // the text first, the palette at the next Escape
              e.stopPropagation();
              setText("");
              setActive(0);
            }
          }}
          placeholder={placeholder}
          ref={input}
          role="combobox"
          type="search"
          value={text}
        />
      </div>
      <ul className="kit-search__list" hidden={!shown.length} id={listId} role="listbox">
        {shown.map((c, i) => (
          <li
            aria-selected={i === at}
            className={"kit-search__item" + (i === at ? " is-active" : "")}
            id={listId + "-" + i}
            key={c.value}
            onClick={() => run(c)}
            onMouseDown={(e) => e.preventDefault()} // the field keeps the focus
            onMouseMove={() => {
              if (i !== at) setActive(i);
            }}
            role="option"
          >
            <span>{c.label}</span>
            {c.meta || c.shortcut ? (
              <span className="kit-search__meta">
                {c.meta}
                {c.meta && c.shortcut ? " " : null}
                {c.shortcut ? <kbd className="kit-kbd">{c.shortcut}</kbd> : null}
              </span>
            ) : null}
          </li>
        ))}
      </ul>
      <p className="kit-empty" hidden={shown.length > 0}>
        {empty}
      </p>
      <span aria-live="polite" className="kit-sr-only">
        {said}
      </span>
    </dialog>
  );
}
