// How change cards (write and edit) start in the chat: expanded, showing the changed lines, or
// collapsed to one line. A choice of this browser (Settings > This browser), kept in localStorage.
import { useEffect, useState } from "react";
import { readStored, writeStored } from "./stored";

export type CardView = "expanded" | "collapsed";

const KEY = "ccb.cardView";
const EVENT = "ccb-card-view";

/** The cards whose view this choice sets: the ones that show a change. */
export const CHANGE_ACTIONS = new Set(["write", "edit"]);

/** The stored choice; expanded when there is none (or storage is blocked). */
export function getCardView(): CardView {
  return readStored(KEY) === "collapsed" ? "collapsed" : "expanded";
}

/** Stores the choice and tells the cards on the page. */
export function setCardView(v: CardView): void {
  writeStored(KEY, v);
  window.dispatchEvent(new Event(EVENT));
}

/** Whether a card for this action starts open under the given choice. */
export function startsOpen(action: string, view: CardView): boolean {
  return view === "expanded" && CHANGE_ACTIONS.has(action);
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
