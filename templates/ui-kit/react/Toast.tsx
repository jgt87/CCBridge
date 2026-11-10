/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { useEffect, useState } from "react";

export type ToastTone = "ok" | "warn" | "error";
interface ToastItem {
  id: number;
  text: string;
  tone?: ToastTone;
  leaving: boolean;
  close: boolean;
  action?: ToastAction;
}
/** One action on a toast (Undo, Retry, Open): clicking it runs onClick and closes the toast. */
export interface ToastAction {
  label: string;
  onClick?: () => void;
}
interface ToastTimer {
  left: number;
  since: number;
  timer: number | null;
}

// A tiny store, so toast() works from anywhere and one Toaster shows them.
let items: ToastItem[] = [];
let nextId = 1;
const timers = new Map<number, ToastTimer>();
const listeners = new Set<(list: ToastItem[]) => void>();
const emit = () => listeners.forEach((l) => l(items));

/** Takes a toast away now (its Dismiss button does this). */
export function dismissToast(id: number) {
  const t = timers.get(id);
  if (t && t.timer !== null) window.clearTimeout(t.timer);
  timers.delete(id);
  if (!items.some((x) => x.id === id && !x.leaving)) return;
  items = items.map((x) => (x.id === id ? { ...x, leaving: true } : x));
  emit();
  window.setTimeout(() => {
    items = items.filter((x) => x.id !== id);
    emit();
  }, 400);
}
function run(id: number) {
  const t = timers.get(id);
  if (!t || t.timer !== null) return;
  t.since = Date.now();
  t.timer = window.setTimeout(() => dismissToast(id), t.left);
}
// While the pointer is on a toast or the focus is in it, its time stands still.
function pause(id: number) {
  const t = timers.get(id);
  if (!t || t.timer === null) return;
  window.clearTimeout(t.timer);
  t.timer = null;
  t.left = Math.max(1000, t.left - (Date.now() - t.since));
}

/**
 * A short confirmation after an action ("Saved"), read out by screen readers; close: false leaves out its
 * Dismiss button; action adds one ghost button, and the toast then stays at least 10 s.
 */
export function toast(text: string, opts: { tone?: ToastTone; ms?: number; close?: boolean; action?: ToastAction } = {}) {
  const id = nextId++;
  const action = opts.action && opts.action.label ? opts.action : undefined;
  items = [...items, { id, text, tone: opts.tone, leaving: false, close: opts.close !== false, action }];
  emit();
  const ms = opts.ms ?? (opts.tone === "error" ? 8000 : 4000);
  timers.set(id, { left: action ? Math.max(ms, 10000) : ms, since: 0, timer: null });
  run(id);
  return id;
}

// The kit's x icon when kit-icons.js is on the page, else the multiplication sign.
function closeMark() {
  const svg = (window as { KitIcons?: { svg: (name: string) => string } }).KitIcons?.svg("x");
  return svg ? <span aria-hidden="true" dangerouslySetInnerHTML={{ __html: svg }} style={{ display: "inline-flex", lineHeight: 0 }} /> : "\u00d7";
}

/** Put once on the page (at the end of the app): the place where toasts show. */
export function Toaster() {
  const [list, setList] = useState<ToastItem[]>(items);
  const [over, setOver] = useState<number | null>(null);
  useEffect(() => {
    listeners.add(setList);
    return () => {
      listeners.delete(setList);
    };
  }, []);
  // An error is read at once (in the alert region, there from the first render, errors on top); the
  // others politely. A warning or error also says its word, not only its colour.
  const item = (t: ToastItem) => (
    <div
      className={"kit-toast" + (t.tone ? " kit-toast--" + t.tone : "") + (t.leaving ? " is-leaving" : "")}
      key={t.id}
      onBlur={(e) => {
        if (over !== t.id && !e.currentTarget.contains(e.relatedTarget as Node | null)) run(t.id);
      }}
      onFocus={() => pause(t.id)}
      onMouseEnter={() => {
        setOver(t.id);
        pause(t.id);
      }}
      onMouseLeave={(e) => {
        setOver(null);
        if (!e.currentTarget.contains(document.activeElement)) run(t.id);
      }}
    >
      {t.tone === "error" || t.tone === "warn" ? <span className="kit-sr-only">{t.tone === "error" ? "Error: " : "Warning: "}</span> : null}
      {t.text}
      {t.action ? (
        <button
          className="kit-btn kit-btn--ghost kit-btn--sm kit-toast__action"
          onClick={() => {
            dismissToast(t.id);
            t.action?.onClick?.();
          }}
          type="button"
        >
          {t.action.label}
        </button>
      ) : null}
      {t.close ? (
        <button aria-label="Dismiss" className="kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm kit-toast__close" onClick={() => dismissToast(t.id)} type="button">
          {closeMark()}
        </button>
      ) : null}
    </div>
  );
  return (
    <div aria-live="polite" className="kit-toasts" role="status">
      <div className="kit-toasts__alerts" role="alert">
        {list.filter((t) => t.tone === "error").map(item)}
      </div>
      {list.filter((t) => t.tone !== "error").map(item)}
    </div>
  );
}

/** The same toast() as a hook, for components that prefer one. */
export function useToast() {
  return toast;
}
