import { CircleX } from "lucide-react";
import { useRef } from "react";
import type { AppState } from "@/lib/api";
import { api } from "@/lib/api";
import { cn } from "@/lib/utils";

const LABELS: Record<AppState["copilot"], string> = {
  idle: "Not started",
  connecting: "Connecting",
  ready: "Connected",
  error: "Not connected",
};

/**
 * Connecting -> connected in one drawn icon: while connecting an arc spins; when the connection is
 * made the arc closes into a circle and a check mark draws itself inside it, with a small pulse.
 * The end state is set by attributes (always right); CSS transitions in index.css animate only
 * the step to connected. Opened while already connected, or with reduced motion: no animation.
 */
function ConnectIcon({ done }: { done: boolean }) {
  // The transition class must be there in the same render as the change to connected, so it is
  // derived here: connected after having been connecting. Opened while connected: no class.
  const sawConnecting = useRef(!done);
  if (!done) sawConnecting.current = true;
  const justDone = done && sawConnecting.current;
  return (
    <svg
      aria-hidden
      className={cn("ccb-connect h-3.5 w-3.5", !done && "animate-spin", justDone && "ccb-connect-done")}
      fill="none"
      stroke="currentColor"
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeWidth={2}
      viewBox="0 0 24 24"
    >
      {/* pathLength 100: dasharray "30 100" = a spinner arc, "100 0" = a closed circle. */}
      <circle cx={12} cy={12} pathLength={100} r={9.5} strokeDasharray={done ? "100 0" : "30 100"} transform="rotate(-90 12 12)" />
      <path d="M8 12.5l2.7 2.7L16.2 9.5" opacity={done ? 1 : 0} pathLength={100} strokeDasharray="100" strokeDashoffset={done ? 0 : 100} />
    </svg>
  );
}

/** Copilot connection state for the header: an icon (spinner that turns into a check, or a cross) and a word. */
export function CopilotStatus({ copilot, message }: { copilot: AppState["copilot"]; message: string }) {
  const tip = message ? `Copilot in Edge: ${message}` : `Copilot in Edge: ${LABELS[copilot].toLowerCase()}`;
  const connecting = copilot === "connecting" || copilot === "ready";
  return (
    <span className="flex items-center gap-1.5 text-muted-foreground text-xs" title={tip}>
      {connecting ? <ConnectIcon done={copilot === "ready"} /> : <CircleX aria-hidden className="h-3.5 w-3.5" />}
      <span>Copilot {LABELS[copilot].toLowerCase()}</span>
      {copilot === "error" && (
        <button className="text-foreground hover:underline" onClick={() => api.connect()} type="button">
          Retry
        </button>
      )}
    </span>
  );
}
