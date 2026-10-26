import { useState } from "react";
import { AlertCircle, Info } from "lucide-react";
import GradientButton from "@/components/kokonutui/gradient-button";
import type { ChatOptions } from "@/lib/api";
import { editsRefusedText, type EditsRefusedItem } from "./edits-refused-view";

/** An answer-only task refused Copilot's edits: apply them as written, or send the request again as a change. */
export function EditsRefusedCard({ item, onSend }: { item: EditsRefusedItem; onSend?: (text: string, opts: ChatOptions) => void }) {
  const [chosen, setChosen] = useState<"" | "apply" | "change">("");
  if (item.restored || chosen) {
    return (
      <div className="flex items-start gap-2 px-1 text-muted-foreground text-sm">
        <Info className="mt-0.5 h-4 w-4" />
        <span>{chosen === "apply" ? "Applying Copilot's edits." : chosen === "change" ? "Sent again as a change." : editsRefusedText(item.count, item.files)}</span>
      </div>
    );
  }
  const send = (how: "apply" | "change") => {
    setChosen(how);
    onSend?.(item.request, how === "apply" ? { replay: item.replayId } : { asChange: true });
  };
  return (
    <div className="kit-panel space-y-2 px-3 py-2 text-sm">
      <div className="flex items-start gap-2">
        <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
        <span>{editsRefusedText(item.count, item.files)}</span>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <GradientButton className="h-10 min-w-44" disabled={!onSend || !item.replayId} label="Apply these edits" onClick={() => send("apply")} variant="neutral" />
        <button className="kit-btn kit-btn--ghost h-10" disabled={!onSend} onClick={() => send("change")} title="Copilot gets your request again, this time as a request to change files" type="button">
          Send again as a change
        </button>
      </div>
    </div>
  );
}
