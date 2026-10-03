import { Columns2, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { api } from "@/lib/api";

const HINT = "splitView";
const LOCAL_KEY = "ccb.hint.splitView";

function seenHere() {
  try {
    return localStorage.getItem(LOCAL_KEY) === "1";
  } catch {
    return false;
  }
}

/**
 * First-time hint: how to put this tab and the Copilot tab side by side with Edge's Split screen.
 * Only in Edge, only when the app opened as a tab in the Copilot window (appWindow copilot-tab),
 * and only once: it is marked as shown in the data folder (and this browser) when it appears.
 */
export function SplitViewHint({ appWindow, shownBefore }: { appWindow?: string; shownBefore: boolean }) {
  const isEdge = typeof navigator !== "undefined" && /\bEdg\//.test(navigator.userAgent);
  const eligible = isEdge && (appWindow ?? "copilot-tab") === "copilot-tab" && !shownBefore && !seenHere();
  const [open, setOpen] = useState(false);
  const marked = useRef(false);

  useEffect(() => {
    if (!eligible || marked.current) return;
    marked.current = true;
    setOpen(true);
    // Shown once means once: recorded right away, not only when dismissed.
    try {
      localStorage.setItem(LOCAL_KEY, "1");
    } catch {
      /* storage blocked: the data folder still records it */
    }
    void api.markHintShown(HINT).catch(() => undefined);
  }, [eligible]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  if (!open) return null;
  // Its own layer on top of everything, the app's top bar included.
  return createPortal(
    // In the page's top-right corner. The pointer sits under Edge's menu button (...), which is just
    // left of Edge's own Copilot button at the far right, so about 60 px from the right edge.
    <div className="fixed top-3.5 right-2 z-[100] w-[22rem] animate-[ccb-hint-nudge_1.6s_ease-in-out_3]" role="dialog" aria-label="Use Split screen in Edge">
      {/* Inverted against the app (light on the dark app, dark on the light one), still without
          color, so it reads as a hint and not as part of the page. */}
      <div className="relative w-full rounded-xl bg-foreground p-4 text-background text-sm shadow-[0_0_0_4px_color-mix(in_oklab,var(--foreground)_18%,transparent),0_18px_50px_rgba(0,0,0,0.55)]">
        <span aria-hidden className="absolute -top-[7px] right-12 h-4 w-4 rotate-45 rounded-tl-sm bg-foreground" />
        <div className="mb-2 flex items-start gap-2">
          <Columns2 className="mt-0.5 h-4 w-4 shrink-0 opacity-70" />
          <div className="flex-1">
            <span className="mr-1.5 rounded bg-background px-1.5 py-px align-[1px] font-semibold text-[10px] text-foreground uppercase tracking-wide">Tip</span>
            <span className="font-semibold">Copilot side by side</span>
          </div>
          <button className="rounded p-0.5 opacity-70 hover:bg-background/15 hover:opacity-100" onClick={() => setOpen(false)} title="Close (Esc)" type="button">
            <X className="h-4 w-4" />
          </button>
        </div>
        <p className="mb-2 text-xs opacity-75">Edge can show this tab and the Copilot tab in one window, so you can watch Copilot work:</p>
        <ol className="list-decimal space-y-1.5 pl-5 text-xs">
          <li>
            Open Edge's menu: the <span className="font-medium">…</span> button at the top right of Edge, where this card points.
          </li>
          <li>
            Choose <span className="font-medium">Split screen</span>. The window splits into two halves.
          </li>
          <li>
            In the right half, Edge lists your open tabs: pick the <span className="font-medium">Copilot</span> tab.
          </li>
          <li>Drag the bar in the middle to give each side the room you want.</li>
        </ol>
        <div className="mt-3 flex justify-end">
          <button
            className="rounded-md bg-background px-3 py-1 font-medium text-foreground text-xs hover:opacity-90"
            onClick={() => setOpen(false)}
            type="button"
          >
            Got it
          </button>
        </div>
      </div>
    </div>,
    document.body
  );
}
