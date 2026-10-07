// How the cards of the steps in the chat (read, edit, run ...) show: expanded (the default: every
// card open), or auto-collapse (a card folds up once its step is finished; what still needs the
// reader, waiting for approval, running or failed, stays open). A choice of this browser
// (Settings > This browser), kept in localStorage.
import { useEffect, useState } from "react";
import { readStored, writeStored } from "./stored";

export type CardView = "expanded" | "auto-collapse";

const KEY = "ccb.cardView";
const EVENT = "ccb-card-view";

/** Steps that still need the reader: their card stays open under auto-collapse. */
const NEEDS_READER = new Set(["awaiting", "running", "failed", "ambiguous"]);

/** The stored choice; expanded when there is none (or storage is blocked). The old "collapsed" is auto-collapse now. */
export function getCardView(): CardView {
  const v = readStored(KEY);
  return v === "auto-collapse" || v === "collapsed" ? "auto-collapse" : "expanded";
}

/** Stores the choice and tells the cards on the page. */
export function setCardView(v: CardView): void {
  writeStored(KEY, v);
  window.dispatchEvent(new Event(EVENT));
}

/** Whether a card with this status is open under the given choice (until the reader opens or closes it). */
export function cardOpen(status: string, view: CardView): boolean {
  return view === "expanded" || NEEDS_READER.has(status);
}

/** The current choice, updated when it changes in Settings. */
export function useCardView(): CardView {
  const [view, setView] = useState<CardView>(getCardView());
  useEffect(() => {
    const on = () => setView(getCardView());
    window.addEventListener(EVENT, on);
    return () => window.removeEventListener(EVENT, on);
  }, []);
  return view;
}
