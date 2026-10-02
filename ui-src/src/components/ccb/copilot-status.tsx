import { CircleCheck, CircleX, LoaderCircle } from "lucide-react";
import type { AppState } from "@/lib/api";
import { api } from "@/lib/api";

const LABELS: Record<AppState["copilot"], string> = {
  idle: "Not started",
  connecting: "Connecting",
  ready: "Connected",
  error: "Not connected",
};

/** Copilot connection state for the header: an icon (check, cross, or a spinner while connecting) and a word. */
export function CopilotStatus({ copilot, message }: { copilot: AppState["copilot"]; message: string }) {
  const tip = message ? `Copilot in Edge: ${message}` : `Copilot in Edge: ${LABELS[copilot].toLowerCase()}`;
  const Icon = copilot === "ready" ? CircleCheck : copilot === "connecting" ? LoaderCircle : CircleX;
  return (
    <span className="flex items-center gap-1.5 text-muted-foreground text-xs" title={tip}>
      <Icon aria-hidden className={copilot === "connecting" ? "h-3.5 w-3.5 animate-spin" : "h-3.5 w-3.5"} />
      <span>Copilot {LABELS[copilot].toLowerCase()}</span>
      {copilot === "error" && (
        <button className="text-foreground hover:underline" onClick={() => api.connect()} type="button">
          Retry
        </button>
      )}
    </span>
  );
}
