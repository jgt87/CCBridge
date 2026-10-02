import type { AppState } from "@/lib/api";
import { api } from "@/lib/api";
import { cn } from "@/lib/utils";

const LABELS: Record<AppState["copilot"], string> = {
  idle: "Not started",
  connecting: "Connecting",
  ready: "Connected",
  error: "Not connected",
};

/** Copilot connection state for the header: a small dot and a word, nothing more. */
export function CopilotStatus({ copilot, message }: { copilot: AppState["copilot"]; message: string }) {
  const tip = message ? `Copilot in Edge: ${message}` : `Copilot in Edge: ${LABELS[copilot].toLowerCase()}`;
  return (
    <span className="flex items-center gap-2 text-muted-foreground text-xs" title={tip}>
      <span
        aria-hidden
        className={cn(
          "h-1.5 w-1.5 rounded-full",
          copilot === "ready" && "bg-foreground/60",
          copilot === "connecting" && "bg-foreground/25",
          (copilot === "idle" || copilot === "error") && "border border-foreground/40",
        )}
      />
      <span>Copilot {LABELS[copilot].toLowerCase()}</span>
      {copilot === "error" && (
        <button className="text-foreground hover:underline" onClick={() => api.connect()} type="button">
          Retry
        </button>
      )}
    </span>
  );
}
