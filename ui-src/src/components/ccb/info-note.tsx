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
          className="-my-0.5 inline-flex rounded p-0.5 align-middle text-muted-foreground hover:bg-black/5 hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring dark:hover:bg-white/10"
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
          className="absolute top-full right-0 left-0 z-30 mt-1 space-y-1 rounded-lg border border-black/10 bg-popover p-2.5 text-popover-foreground text-xs leading-relaxed shadow-lg dark:border-white/10"
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
