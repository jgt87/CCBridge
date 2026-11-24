import { useState } from "react";
import { cn } from "@/lib/utils";

const buttonClass = "kit-btn kit-btn--ghost kit-btn--sm shrink-0";

/**
 * A Remove button that asks once more in place ("Remove sales?" with Remove and Cancel), as "Reset all
 * to defaults" does in Settings: removing a saved link or connection has no undo. Focus goes to Cancel,
 * so a second Enter or Space never removes by accident.
 */
export function ConfirmRemove({ name, disabled, onRemove, className }: { name: string; disabled?: boolean; onRemove: () => void; className?: string }) {
  const [asking, setAsking] = useState(false);
  if (!asking) {
    return (
      <button aria-label={`Remove ${name}`} className={cn(buttonClass, className)} disabled={disabled} onClick={() => setAsking(true)} type="button">
        Remove
      </button>
    );
  }
  return (
    <span className={cn("flex shrink-0 items-center gap-1.5", className)}>
      <span className="text-muted-foreground">Remove {name}?</span>
      <button
        className={cn(buttonClass, "bg-(--kit-surface-2)")}
        disabled={disabled}
        onClick={() => {
          setAsking(false);
          onRemove();
        }}
        type="button"
      >
        Remove
      </button>
      {/* The question replaced the focused Remove button: Cancel takes its focus. */}
      <button autoFocus className={buttonClass} onClick={() => setAsking(false)} type="button">
        Cancel
      </button>
    </span>
  );
}
