import { Info } from "lucide-react";
import { useEffect, useId, useRef, useState } from "react";

// The shared hover timing: the box waits a moment on the first hover (a pointer passing over does not
// open it), and leaving has a short guard, cancelled when the pointer comes back. Focus opens it at once.
const HOVER_IN_MS = 500;
const HOVER_OUT_MS = 150;

/**
 * A short line of explanation with an info button: the details show in a box under the line while
 * the pointer rests on the button or it has focus (a click keeps it open, for touch screens).
 */
export function InfoNote({ children, details }: { children: React.ReactNode; details: React.ReactNode }) {
  const [hover, setHover] = useState(false);
  const [pinned, setPinned] = useState(false);
  const id = useId();
  const timer = useRef<number | null>(null);
  const later = (show: boolean, ms: number) => {
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => {
      timer.current = null;
      setHover(show);
    }, ms);
  };
  const now = (show: boolean) => {
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = null;
    setHover(show);
  };
  useEffect(() => () => {
    if (timer.current !== null) window.clearTimeout(timer.current);
  }, []);
  const open = hover || pinned;
  return (
    <div className="relative">
      <p className="text-muted-foreground text-xs">
        {children}{" "}
        <button
          aria-describedby={open ? id : undefined}
          aria-expanded={open}
          aria-label="More about this"
          className="kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm -my-1.5 h-6 w-6 min-h-0 align-middle text-muted-foreground hover:text-foreground"
          onBlur={() => (setPinned(false), now(false))}
          onClick={() => setPinned((p) => !p)}
          onFocus={() => now(true)}
          onMouseEnter={() => (hover ? now(true) : later(true, HOVER_IN_MS))}
          onMouseLeave={() => later(false, HOVER_OUT_MS)}
          onKeyDown={(e) => e.key === "Escape" && (setPinned(false), now(false))}
          type="button"
        >
          <Info className="h-3.5 w-3.5" />
        </button>
      </p>
      {open && (
        <div
          className="kit-popover absolute top-full right-0 left-0 mt-1 w-auto min-w-0 max-w-none space-y-1 p-2.5 text-xs leading-relaxed"
          id={id}
          onMouseEnter={() => now(true)}
          onMouseLeave={() => later(false, HOVER_OUT_MS)}
          role="tooltip"
        >
          {details}
        </div>
      )}
    </div>
  );
}
