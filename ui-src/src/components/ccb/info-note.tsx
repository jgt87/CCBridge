import { Info } from "lucide-react";
import { useId, useState } from "react";

/**
 * A short line of explanation with an info button: the details show in a box under the line while
 * the pointer is on the button or it has focus (a click keeps it open, for touch screens).
 */
export function InfoNote({ children, details }: { children: React.ReactNode; details: React.ReactNode }) {
  const [hover, setHover] = useState(false);
  const [pinned, setPinned] = useState(false);
  const id = useId();
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
          onBlur={() => (setPinned(false), setHover(false))}
          onClick={() => setPinned((p) => !p)}
          onFocus={() => setHover(true)}
          onMouseEnter={() => setHover(true)}
          onMouseLeave={() => setHover(false)}
          onKeyDown={(e) => e.key === "Escape" && (setPinned(false), setHover(false))}
          type="button"
        >
          <Info className="h-3.5 w-3.5" />
        </button>
      </p>
      {open && (
        <div
          className="kit-popover absolute top-full right-0 left-0 mt-1 w-auto min-w-0 max-w-none space-y-1 p-2.5 text-xs leading-relaxed"
          id={id}
          onMouseEnter={() => setHover(true)}
          onMouseLeave={() => setHover(false)}
          role="tooltip"
        >
          {details}
        </div>
      )}
    </div>
  );
}
