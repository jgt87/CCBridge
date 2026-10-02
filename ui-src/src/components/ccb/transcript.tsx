import { AlertCircle, CheckCircle2, Hand, Info, Link2, RotateCcw, User } from "lucide-react";
import { useEffect, useRef } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import AITextLoading from "@/components/kokonutui/ai-text-loading";
import type { AgentEvent, Reference } from "@/lib/api";
import { stripActionBlocks } from "@/lib/diff";
import { cn } from "@/lib/utils";
import { ActionCard, type ActionItem } from "./action-card";

type NoteTone = "info" | "error" | "done" | "undo" | "human";

export type TranscriptItem =
  | { kind: "user"; seq: number; text: string }
  | { kind: "assistant"; seq: number; text: string; uncertain: number; references: Reference[] }
  | { kind: "action"; seq: number; item: ActionItem }
  | { kind: "note"; seq: number; tone: NoteTone; text: string }
  | { kind: "next"; seq: number; steps: string[] };

// --- Building the transcript from events ------------------------------------------------

interface BuildContext {
  items: TranscriptItem[];
  actions: Map<string, ActionItem>;
}

/** Event types shown as a one-line note: tone, and the text used when the event has none. */
const NOTE_EVENTS: Partial<Record<AgentEvent["type"], { tone: NoteTone; fallback: string; keepEmpty?: boolean }>> = {
  done: { tone: "done", fallback: "Done.", keepEmpty: false },
  status: { tone: "info", fallback: "" },
  error: { tone: "error", fallback: "" },
  undo: { tone: "undo", fallback: "" },
  newchat: { tone: "info", fallback: "New Copilot chat started." },
  fetch: { tone: "done", fallback: "Fetched." },
  "human-required": { tone: "human", fallback: "" },
};

function addNote(e: AgentEvent, ctx: BuildContext) {
  const note = NOTE_EVENTS[e.type];
  if (!note) return;
  // "done" also replaces an empty string; the other notes only replace a missing text.
  const text = note.keepEmpty === false ? e.text || note.fallback : (e.text ?? note.fallback);
  ctx.items.push({ kind: "note", seq: e.seq, tone: note.tone, text });
}

/** An action event creates the card the first time and updates it afterwards. */
function mergeAction(e: AgentEvent, ctx: BuildContext) {
  const existing = ctx.actions.get(e.id!);
  const next: ActionItem = {
    ...(existing ?? { id: e.id!, action: e.action!, target: e.target ?? "", status: "running" }),
    status: e.status ?? "running",
    preview: e.preview ?? existing?.preview,
    warning: e.warning ?? existing?.warning,
    error: e.error ?? existing?.error,
    target: e.target ?? existing?.target ?? "",
  };
  ctx.actions.set(e.id!, next);
  if (!existing) ctx.items.push({ kind: "action", seq: e.seq, item: next });
}

/** An action-result event updates the card of its action (results without a card are ignored). */
function mergeActionResult(e: AgentEvent, ctx: BuildContext) {
  const existing = ctx.actions.get(e.id!);
  if (!existing) return;
  Object.assign(existing, {
    status: e.status ?? existing.status,
    summary: e.summary ?? existing.summary,
    output: e.output ?? existing.output,
    decidedBy: e.decidedBy ?? existing.decidedBy,
  });
}

const HANDLERS: Partial<Record<AgentEvent["type"], (e: AgentEvent, ctx: BuildContext) => void>> = {
  user: (e, ctx) => ctx.items.push({ kind: "user", seq: e.seq, text: e.text ?? "" }),
  "next-steps": (e, ctx) => {
    if (e.steps?.length) ctx.items.push({ kind: "next", seq: e.seq, steps: e.steps });
  },
  assistant: (e, ctx) =>
    ctx.items.push({ kind: "assistant", seq: e.seq, text: e.text ?? "", uncertain: e.uncertain ?? 0, references: e.references ?? [] }),
  action: mergeAction,
  "action-result": mergeActionResult,
};

/** Folds the event stream into transcript items; action + action-result events merge by id. */
export function buildTranscript(events: AgentEvent[]): TranscriptItem[] {
  const ctx: BuildContext = { items: [], actions: new Map() };
  for (const e of events) (HANDLERS[e.type] ?? addNote)(e, ctx);
  // Re-create action items so React sees the merged state.
  return ctx.items.map((it) => (it.kind === "action" ? { ...it, item: { ...ctx.actions.get(it.item.id)! } } : it));
}

// --- Rendering ---------------------------------------------------------------------------

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

function UserMessage({ text }: { text: string }) {
  return (
    <div className="flex justify-end">
      <div className="flex max-w-[85%] items-start gap-2 rounded-2xl rounded-tr-sm bg-black/5 px-4 py-2.5 text-sm dark:bg-white/10">
        <span className="whitespace-pre-wrap">{text}</span>
        <User className="mt-0.5 h-3.5 w-3.5 shrink-0 opacity-50" />
      </div>
    </div>
  );
}

function AssistantMessage({ text, references }: { text: string; references: Reference[] }) {
  const visible = stripActionBlocks(text);
  if (!visible && !references.length) return null;
  return (
    <div className="px-1">
      {visible && <Markdown text={visible} />}
      {references.length > 0 && <Sources refs={references} />}
    </div>
  );
}

function NoteLine({ tone, text }: { tone: NoteTone; text: string }) {
  const style = NOTE_STYLE[tone];
  return (
    <div className={cn("flex items-start gap-2 px-1 text-sm", style.cls)}>
      <span className="mt-0.5">{style.icon}</span>
      <span className="whitespace-pre-wrap">{text}</span>
    </div>
  );
}

/** Follow-ups Copilot suggested; a click puts the text in the message box (nothing is sent yet). */
function NextSteps({ steps, onUse }: { steps: string[]; onUse?: (text: string) => void }) {
  return (
    <div className="rounded-xl border border-black/10 border-dashed px-3 py-2 dark:border-white/10">
      <div className="mb-1.5 text-muted-foreground text-xs">Suggested next steps (click one to put it in the message box)</div>
      <div className="flex flex-col gap-1">
        {steps.map((s, i) => (
          <button
            className="w-full rounded-md px-2 py-1 text-left text-sm hover:bg-black/5 disabled:opacity-50 dark:hover:bg-white/5"
            disabled={!onUse}
            key={`${i}-${s}`}
            onClick={() => onUse?.(s)}
            title={s}
            type="button"
          >
            <span className="mr-1.5 text-muted-foreground">{i + 1}.</span>
            <span className="line-clamp-2">{s}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

function TranscriptRow({ item, onUsePrompt }: { item: TranscriptItem; onUsePrompt?: (text: string) => void }) {
  switch (item.kind) {
    case "user":
      return <UserMessage text={item.text} />;
    case "assistant":
      return <AssistantMessage references={item.references} text={item.text} />;
    case "action":
      return <ActionCard item={item.item} />;
    case "note":
      return <NoteLine text={item.text} tone={item.tone} />;
    case "next":
      return <NextSteps onUse={onUsePrompt} steps={item.steps} />;
  }
}

function thinkingTexts(progress: string, stopping: boolean): string[] {
  if (stopping) return ["Stopping..."];
  if (progress) return ["Copilot is writing...", "Receiving the reply..."];
  return ["Asking Copilot...", "Waiting for the reply...", "Copilot is thinking..."];
}

function ThinkingIndicator({ progress, stopping }: { progress: string; stopping: boolean }) {
  return (
    <div className="rounded-xl border border-black/10 border-dashed px-3 py-2 dark:border-white/10">
      <AITextLoading
        className="font-semibold text-base"
        containerClassName="justify-start p-0"
        interval={1800}
        texts={thinkingTexts(progress, stopping)}
      />
      {progress && (
        <pre className="mt-2 max-h-32 overflow-hidden whitespace-pre-wrap font-mono text-muted-foreground text-xs [mask-image:linear-gradient(to_bottom,transparent,black_40%)]">
          {progress.slice(-700)}
        </pre>
      )}
    </div>
  );
}

const rowKey = (it: TranscriptItem) => (it.kind === "action" ? it.item.id : it.seq);

export function Transcript({
  items,
  busy,
  progress,
  empty,
  stopping = false,
  onUsePrompt,
}: {
  items: TranscriptItem[];
  busy: boolean;
  progress: string;
  empty?: React.ReactNode;
  stopping?: boolean;
  /** Puts a suggested next step in the message box. */
  onUsePrompt?: (text: string) => void;
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
      {items.map((it) => (
        <TranscriptRow item={it} key={rowKey(it)} onUsePrompt={onUsePrompt} />
      ))}
      {busy && !awaiting && <ThinkingIndicator progress={progress} stopping={stopping} />}
      <div ref={endRef} />
    </div>
  );
}
