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
}

// A tiny store, so toast() works from anywhere and one Toaster shows them.
let items: ToastItem[] = [];
let nextId = 1;
const listeners = new Set<(list: ToastItem[]) => void>();
const emit = () => listeners.forEach((l) => l(items));

/** A short confirmation after an action ("Saved"), read out by screen readers. */
export function toast(text: string, opts: { tone?: ToastTone; ms?: number } = {}) {
  const id = nextId++;
  items = [...items, { id, text, tone: opts.tone, leaving: false }];
  emit();
  const ms = opts.ms ?? (opts.tone === "error" ? 8000 : 4000);
  setTimeout(() => {
    items = items.map((t) => (t.id === id ? { ...t, leaving: true } : t));
    emit();
    setTimeout(() => {
      items = items.filter((t) => t.id !== id);
      emit();
    }, 400);
  }, ms);
  return id;
}

/** Put once on the page (at the end of the app): the place where toasts show. */
export function Toaster() {
  const [list, setList] = useState<ToastItem[]>(items);
  useEffect(() => {
    listeners.add(setList);
    return () => {
      listeners.delete(setList);
    };
  }, []);
  return (
    <div aria-live="polite" className="kit-toasts" role="status">
      {list.map((t) => (
        <div className={"kit-toast" + (t.tone ? " kit-toast--" + t.tone : "") + (t.leaving ? " is-leaving" : "")} key={t.id}>
          {t.text}
        </div>
      ))}
    </div>
  );
}

/** The same toast() as a hook, for components that prefer one. */
export function useToast() {
  return toast;
}
