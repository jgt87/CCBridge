// The result of "Check this page in full" (command menu) in the chat: the summary with counts, the
// report to open, and one button that sends the findings to Copilot as a fix list (a coding task).
// Nothing sends it by itself: the person decides.
import { ClipboardCheck } from "lucide-react";
import { useState } from "react";
import type { ChatOptions } from "@/lib/api";
import GradientButton from "@/components/kokonutui/gradient-button";
import { canSendFixList, type PageReportItem } from "./page-report";

export function PageReportCard({
  item,
  onSend,
  onOpenFile,
}: {
  item: PageReportItem;
  onSend?: (text: string, opts: ChatOptions) => void;
  onOpenFile?: (path: string) => void;
}) {
  const [sent, setSent] = useState(false);
  const offer = item.fixRequest.trim() !== "" && !item.restored;
  return (
    <div className="kit-panel space-y-2 px-3 py-2 text-sm">
      <div className="flex items-start gap-2">
        <ClipboardCheck className="mt-0.5 h-4 w-4 shrink-0" />
        <span className="min-w-0 [overflow-wrap:anywhere]">{item.text}</span>
      </div>
      {item.path && onOpenFile && (
        <button className="kit-link ml-6 text-left text-xs no-underline hover:underline" onClick={() => onOpenFile(item.path)} title={`Open ${item.path}`} type="button">
          Open the report
        </button>
      )}
      {offer && (
        <div className="flex flex-wrap items-center gap-2">
          <GradientButton
            className="h-10 min-w-44"
            disabled={!canSendFixList(item, sent, Boolean(onSend))}
            label={sent ? "Sent to Copilot" : "Send to Copilot as a fix list"}
            onClick={() => {
              setSent(true);
              onSend?.(item.fixRequest, { asCoding: true });
            }}
            variant="neutral"
          />
        </div>
      )}
    </div>
  );
}
