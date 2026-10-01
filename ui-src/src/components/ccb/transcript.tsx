import { AlertCircle, CheckCircle2, Hand, Info, Link2, RotateCcw, User } from "lucide-react";
import { useEffect, useRef } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import AITextLoading from "@/components/kokonutui/ai-text-loading";
import type { AgentEvent, Reference } from "@/lib/api";
import { stripActionBlocks } from "@/lib/diff";
import { cn } from "@/lib/utils";
import { ActionCard, type ActionItem } from "./action-card";

export type TranscriptItem =
  | { kind: "user"; seq: number; text: string }
  | { kind: "assistant"; seq: number; text: string; uncertain: number; references: Reference[] }
  | { kind: "action"; seq: number; item: ActionItem }
  | { kind: "note"; seq: number; tone: "info" | "error" | "done" | "undo" | "human"; text: string };

/** Folds the event stream into transcript items; action + action-result events merge by id. */
export function buildTranscript(events: AgentEvent[]): TranscriptItem[] {
  const items: TranscriptItem[] = [];
  const actions = new Map<string, ActionItem>();
  for (const e of events) {
    switch (e.type) {
      case "user":
        items.push({ kind: "user", seq: e.seq, text: e.text ?? "" });
        break;
      case "assistant":
        items.push({ kind: "assistant", seq: e.seq, text: e.text ?? "", uncertain: e.uncertain ?? 0, references: e.references ?? [] });
        break;
      case "action": {
        const existing = actions.get(e.id!);
        const next: ActionItem = {
          ...(existing ?? { id: e.id!, action: e.action!, target: e.target ?? "", status: "running" }),
          status: e.status ?? "running",
          preview: e.preview ?? existing?.preview,
          warning: e.warning ?? existing?.warning,
          error: e.error ?? existing?.error,
          target: e.target ?? existing?.target ?? "",
        };
        actions.set(e.id!, next);
        if (!existing) items.push({ kind: "action", seq: e.seq, item: next });
        break;
      }
      case "action-result": {
        const existing = actions.get(e.id!);
        if (existing) {
          Object.assign(existing, {
            status: e.status ?? existing.status,
            summary: e.summary ?? existing.summary,
            output: e.output ?? existing.output,
          });
        }
        break;
      }
      case "done":
        items.push({ kind: "note", seq: e.seq, tone: "done", text: e.text || "Done." });
        break;
      case "status":
        items.push({ kind: "note", seq: e.seq, tone: "info", text: e.text ?? "" });
        break;
      case "error":
        items.push({ kind: "note", seq: e.seq, tone: "error", text: e.text ?? "" });
        break;
      case "undo":
        items.push({ kind: "note", seq: e.seq, tone: "undo", text: e.text ?? "" });
        break;
      case "newchat":
        items.push({ kind: "note", seq: e.seq, tone: "info", text: e.text ?? "New Copilot chat started." });
        break;
      case "human-required":
        items.push({ kind: "note", seq: e.seq, tone: "human", text: e.text ?? "" });
        break;

    }
  }
  // Re-create action items so React sees the merged state.
  return items.map((it) => (it.kind === "action" ? { ...it, item: { ...actions.get(it.item.id)! } } : it));
}

function Markdown({ text }: { text: string }) {
  return (
    <div className="ccb-markdown text-sm leading-relaxed">
      <ReactMarkdown remarkPlugins={[remarkGfm]}>{text}</ReactMarkdown>
    </div>
  );
}

/** Sources Copilot cited: with Work IQ these are emails, Teams chats, meetings and files. */
function Sources({ refs }: { refs: Reference[] }) {
  return (
    <div className="mt-2 flex flex-wrap items-center gap-1.5 text-xs">
      <span className="text-muted-foreground">Sources</span>
      {refs.map((r, i) => {
        const label = `${r.kind ? `${r.kind}: ` : ""}${r.title ?? r.url ?? "source"}`;
        const cls = "inline-flex max-w-72 items-center gap-1 truncate rounded-md bg-black/5 px-2 py-0.5 text-foreground/80 dark:bg-white/10";
        return r.url ? (
          <a className={`${cls} hover:bg-black/10 dark:hover:bg-white/15`} href={r.url} key={i} rel="noreferrer" target="_blank" title={label}>
            <Link2 className="h-3 w-3 shrink-0" />
            <span className="truncate">{label}</span>
          </a>
        ) : (
          <span className={cls} key={i} title={label}>
            {label}
          </span>
        );
      })}
    </div>
  );
}

const NOTE_STYLE = {
  info: { icon: <Info className="h-4 w-4" />, cls: "text-muted-foreground" },
  error: { icon: <AlertCircle className="h-4 w-4" />, cls: "text-rose-500" },
  done: { icon: <CheckCircle2 className="h-4 w-4" />, cls: "text-foreground" },
  undo: { icon: <RotateCcw className="h-4 w-4" />, cls: "text-muted-foreground" },
  human: {
    icon: <Hand className="h-4 w-4" />,
    cls: "rounded-lg border border-black/20 bg-black/5 px-3 py-2 font-medium text-foreground dark:border-white/25 dark:bg-white/10",
  },
};

export function Transcript({
  items,
  busy,
  progress,
  empty,
  stopping = false,
}: {
  items: TranscriptItem[];
  busy: boolean;
  progress: string;
  empty?: React.ReactNode;
  stopping?: boolean;
}) {
  const endRef = useRef<HTMLDivElement>(null);
  const awaiting = items.some((i) => i.kind === "action" && i.item.status === "awaiting");

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [items.length, busy, awaiting, progress.length > 0]);

  // A fresh chat shows the welcome view until something happens in it.
  if (!busy && items.every((i) => i.kind === "note" && i.tone === "info")) return <>{empty}</>;

  return (
    <div className="mx-auto flex w-full max-w-3xl flex-col gap-3 px-4 py-6">
      {items.map((it) => {
        if (it.kind === "user")
          return (
            <div className="flex justify-end" key={it.seq}>
              <div className="flex max-w-[85%] items-start gap-2 rounded-2xl rounded-tr-sm bg-black/5 px-4 py-2.5 text-sm dark:bg-white/10">
                <span className="whitespace-pre-wrap">{it.text}</span>
                <User className="mt-0.5 h-3.5 w-3.5 shrink-0 opacity-50" />
              </div>
            </div>
          );
        if (it.kind === "assistant") {
          const visible = stripActionBlocks(it.text);
          if (!visible && !it.references.length) return null;
          return (
            <div className="px-1" key={it.seq}>
              {visible && <Markdown text={visible} />}
              {it.references.length > 0 && <Sources refs={it.references} />}
            </div>
          );
        }
        if (it.kind === "action") return <ActionCard item={it.item} key={it.item.id} />;
        const style = NOTE_STYLE[it.tone];
        return (
          <div className={cn("flex items-start gap-2 px-1 text-sm", style.cls)} key={it.seq}>
            <span className="mt-0.5">{style.icon}</span>
            <span className="whitespace-pre-wrap">{it.text}</span>
          </div>
        );
      })}

      {busy && !awaiting && (
        <div className="rounded-xl border border-black/10 border-dashed px-3 py-2 dark:border-white/10">
          <AITextLoading
            className="font-semibold text-base"
            containerClassName="justify-start p-0"
            interval={1800}
            texts={stopping ? ["Stopping..."] : progress ? ["Copilot is writing...", "Receiving the reply..."] : ["Asking Copilot...", "Waiting for the reply...", "Copilot is thinking..."]}
          />
          {progress && (
            <pre className="mt-2 max-h-32 overflow-hidden whitespace-pre-wrap font-mono text-muted-foreground text-xs [mask-image:linear-gradient(to_bottom,transparent,black_40%)]">
              {progress.slice(-700)}
            </pre>
          )}
        </div>
      )}
      <div ref={endRef} />
    </div>
  );
}
