import { openExternal } from "@/lib/links";
import { AlertCircle, CheckCircle2, Hand, Info, Link2, RotateCcw, User } from "lucide-react";
import { AgentPlanCard, ClarifyCard, type ClarifyQuestion, PlanCard } from "./plan-cards";
import type { ChatOptions } from "@/lib/api";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { MarkdownView } from "./markdown-view";
import AITextLoading from "@/components/kokonutui/ai-text-loading";
import type { Activity, AgentEvent, CheckFinding, Preview, Reference, UndoChange } from "@/lib/api";
import { ChecksCard } from "./checks-card";
import { UndoCard } from "./undo-card";
import { stripActionBlocks } from "@/lib/diff";
import { thinkingTexts } from "@/lib/thinking-texts";
import { cn } from "@/lib/utils";
import { ActionCard, type ActionItem } from "./action-card";

type NoteTone = "info" | "error" | "done" | "undo" | "human";

export type TranscriptItem =
  | { kind: "user"; seq: number; text: string; taskKind?: string; agent?: string }
  | { kind: "assistant"; seq: number; text: string; uncertain: number; references: Reference[]; agent?: string }
  | { kind: "agentPlan"; seq: number; agent: string }
  | { kind: "action"; seq: number; item: ActionItem }
  | { kind: "note"; seq: number; tone: NoteTone; text: string; path?: string }
  | { kind: "undo"; seq: number; text: string; changes: UndoChange[] }
  | { kind: "next"; seq: number; steps: string[] }
  | { kind: "clarify"; seq: number; request: string; questions: ClarifyQuestion[]; summary?: string; planId?: string }
  | { kind: "plan"; seq: number; request: string; plan: string; planId?: string }
  | { kind: "error"; seq: number; text: string; time: string; errId?: string; code?: string; hint?: string; detail?: string; version?: string }
  | { kind: "checks"; seq: number; text: string; items: CheckFinding[] };

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
  newchat: { tone: "info", fallback: "New chat started." },
  fetch: { tone: "done", fallback: "Runbook finished." },
  runbook: { tone: "done", fallback: "Runbook finished." },
  chain: { tone: "done", fallback: "Chain finished." },
  script: { tone: "done", fallback: "Script finished." },
  review: { tone: "done", fallback: "Code review finished." },
  "human-required": { tone: "human", fallback: "" },
};

/** An undo with per-file details becomes a card; an older one without them stays a note. */
function addUndo(e: AgentEvent, ctx: BuildContext) {
  const changes = Array.isArray(e.changes) ? e.changes : e.changes ? [e.changes] : [];
  if (!changes.length) return addNote(e, ctx);
  ctx.items.push({ kind: "undo", seq: e.seq, text: e.text ?? "Undid the last change set", changes });
}

function addNote(e: AgentEvent, ctx: BuildContext) {
  const note = NOTE_EVENTS[e.type];
  if (!note) return;
  // "done" also replaces an empty string; the other notes only replace a missing text.
  const text = note.keepEmpty === false ? e.text || note.fallback : (e.text ?? note.fallback);
  ctx.items.push({ kind: "note", seq: e.seq, tone: note.tone, text, ...(typeof e.path === "string" && e.path ? { path: e.path } : {}) });
}

/** An action event creates the card the first time and updates it afterwards. */
/** An action's preview as the card expects it. Older script runs (also in saved chat history) sent
 *  the script as plain text; that becomes a preview of the script itself. */
export function asPreview(p: unknown, target?: string): Preview | undefined {
  if (p == null) return undefined;
  if (typeof p === "string") return { path: (target ?? "").match(/Scripts[\\/][^"\s]+/i)?.[0]?.replace(/\\/g, "/") ?? "", exists: true, old: null, new: p };
  return typeof p === "object" ? (p as Preview) : undefined;
}

function mergeAction(e: AgentEvent, ctx: BuildContext) {
  const existing = ctx.actions.get(e.id!);
  const next: ActionItem = {
    ...(existing ?? { id: e.id!, action: e.action!, target: e.target ?? "", status: "running" }),
    status: e.status ?? "running",
    preview: asPreview(e.preview, e.target) ?? existing?.preview,
    warning: e.warning ?? existing?.warning,
    error: e.error ?? existing?.error,
    target: e.target ?? existing?.target ?? "",
    by: (e as AgentEvent & { by?: string }).by ?? existing?.by,
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
    code: e.code ?? existing.code,
    reasons: e.reasons ?? existing.reasons,
    next: e.next ?? existing.next,
  });
}

const HANDLERS: Partial<Record<AgentEvent["type"], (e: AgentEvent, ctx: BuildContext) => void>> = {
  user: (e, ctx) => ctx.items.push({ kind: "user", seq: e.seq, text: e.text ?? "", ...(e.agent ? { agent: e.agent } : {}) }),
  "agent-plan": (e, ctx) => ctx.items.push({ kind: "agentPlan", seq: e.seq, agent: e.agent || "Researcher" }),
  // How the last message was sent (chat, project, coding, ...): shown under it.
  kind: (e, ctx) => {
    for (let i = ctx.items.length - 1; i >= 0; i--) {
      const it = ctx.items[i];
      if (it.kind === "user") {
        ctx.items[i] = { ...it, taskKind: (e as { taskKind?: string }).taskKind };
        break;
      }
    }
  },
  error: (e, ctx) =>
    ctx.items.push({ kind: "error", seq: e.seq, text: e.text ?? "", time: e.time, errId: e.errId, code: e.code, hint: e.hint, detail: e.detail, version: e.version }),
  clarify: (e, ctx) => {
    const x = e as AgentEvent & { request?: string; questions?: ClarifyQuestion[] | ClarifyQuestion; summary?: string; planId?: string };
    const qs = (Array.isArray(x.questions) ? x.questions : x.questions ? [x.questions] : []).map((q) => ({ question: q.question, options: Array.isArray(q.options) ? q.options : q.options ? [q.options as unknown as string] : [] }));
    if (qs.length) ctx.items.push({ kind: "clarify", seq: e.seq, request: x.request ?? "", questions: qs, summary: x.summary, planId: x.planId || undefined });
  },
  "plan-ready": (e, ctx) => {
    const x = e as AgentEvent & { request?: string; plan?: string; planId?: string };
    if (x.plan) ctx.items.push({ kind: "plan", seq: e.seq, request: x.request ?? "", plan: x.plan, planId: x.planId || undefined });
  },
  "next-steps": (e, ctx) => {
    if (e.steps?.length) ctx.items.push({ kind: "next", seq: e.seq, steps: e.steps });
  },
  assistant: (e, ctx) =>
    ctx.items.push({ kind: "assistant", seq: e.seq, text: e.text ?? "", uncertain: e.uncertain ?? 0, references: e.references ?? [], ...(e.agent ? { agent: e.agent } : {}) }),
  action: mergeAction,
  "action-result": mergeActionResult,
  checks: (e, ctx) => {
    const items = Array.isArray(e.findings) ? e.findings : e.findings ? [e.findings as unknown as CheckFinding] : [];
    if (items.length) ctx.items.push({ kind: "checks", seq: e.seq, text: e.text ?? "", items });
  },
  undo: addUndo,
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
  return <MarkdownView frontMatter={false} text={text} />;
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
          <a className={`${cls} hover:bg-black/10 dark:hover:bg-white/15`} href={r.url} key={i} onClick={openExternal} rel="noreferrer" target="_blank" title={label}>
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
  error: { icon: <AlertCircle className="h-4 w-4" />, cls: "text-rose-500 dark:text-rose-400" },
  done: { icon: <CheckCircle2 className="h-4 w-4" />, cls: "text-foreground" },
  undo: { icon: <RotateCcw className="h-4 w-4" />, cls: "text-muted-foreground" },
  human: {
    icon: <Hand className="h-4 w-4" />,
    cls: "rounded-lg border border-black/20 bg-black/5 px-3 py-2 font-medium text-foreground dark:border-white/25 dark:bg-white/10",
  },
};

const KIND_LABEL: Record<string, string> = { chat: "sent as plain chat", project: "sent as project work (no code instructions)", assistant: "sent as a Microsoft 365 question" };

function UserMessage({ text, taskKind, agent, onResendAsCoding }: { text: string; taskKind?: string; agent?: string; onResendAsCoding?: (text: string) => void }) {
  const label = taskKind ? KIND_LABEL[taskKind] : undefined;
  return (
    <div className="flex flex-col items-end gap-1">
      {agent && <span className="rounded-full border border-black/15 px-2 py-0.5 text-muted-foreground text-xs dark:border-white/20">to {agent}</span>}
      <div className="flex max-w-[85%] items-start gap-2 rounded-2xl rounded-tr-sm bg-black/5 px-4 py-2.5 text-sm dark:bg-white/10">
        <span className="whitespace-pre-wrap">{text}</span>
        <User className="mt-0.5 h-3.5 w-3.5 shrink-0 opacity-50" />
      </div>
      {label && onResendAsCoding && (
        <div className="flex items-center gap-2 text-muted-foreground text-xs">
          <span>{label}</span>
          <button className="rounded-md px-1.5 py-0.5 hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5" onClick={() => onResendAsCoding(text)} title="Send it again with the coding instructions and the project's files" type="button">
            Send again as a coding task
          </button>
        </div>
      )}
    </div>
  );
}

function AssistantMessage({ text, references, agent }: { text: string; references: Reference[]; agent?: string }) {
  const visible = stripActionBlocks(text);
  if (!visible && !references.length) return null;
  return (
    <div className="px-1">
      {agent && (
        <span className="mb-1 inline-block rounded-full border border-black/15 px-2 py-0.5 text-muted-foreground text-xs dark:border-white/20" title={`Answered by Copilot's ${agent} agent (from Copilot's reply)`}>
          {agent}
        </span>
      )}
      {visible && <Markdown text={visible} />}
      {references.length > 0 && <Sources refs={references} />}
    </div>
  );
}

function NoteLine({ tone, text, path, onOpenFile }: { tone: NoteTone; text: string; path?: string; onOpenFile?: (path: string) => void }) {
  const style = NOTE_STYLE[tone];
  return (
    <div className={cn("flex items-start gap-2 px-1 text-sm", style.cls)}>
      <span className="mt-0.5">{style.icon}</span>
      {/* A note about a saved file (task report, chart): the note itself opens it. */}
      {path && onOpenFile ? (
        <button className="whitespace-pre-wrap text-left underline-offset-2 hover:underline" onClick={() => onOpenFile(path)} title={`Open ${path}`} type="button">
          {text}
        </button>
      ) : (
        <span className="whitespace-pre-wrap">{text}</span>
      )}
    </div>
  );
}

/** An error with what is needed to investigate it: category, what to do, and the details to copy. */
function ErrorNote({ item }: { item: Extract<TranscriptItem, { kind: "error" }> }) {
  const [copied, setCopied] = useState(false);
  const details = [
    `StreamHub ${item.version ?? ""} | error ${item.errId ?? "-"} | ${item.time} | ${item.code ?? "UNEXPECTED"}`,
    item.text,
    item.hint ? `What to do: ${item.hint}` : "",
    item.detail ? `Detail:\n${item.detail}` : "",
  ]
    .filter(Boolean)
    .join("\n");
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(details);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch {
      /* clipboard blocked: the details stay visible in the tooltip */
    }
  };
  return (
    <div className="space-y-1 px-1 text-sm">
      <NoteLine text={item.text} tone="error" />
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1 pl-6 text-muted-foreground text-xs" title={details}>
        {item.code && <span className="rounded bg-black/5 px-1.5 py-0.5 font-mono dark:bg-white/10">{item.code}</span>}
        {item.hint && <span>{item.hint}</span>}
        <button className="text-foreground hover:underline" onClick={copy} type="button">
          {copied ? "Copied" : "Copy details"}
        </button>
        {item.errId && <span className="font-mono">{item.errId}</span>}
      </div>
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

function TranscriptRow({
  item,
  onUsePrompt,
  onResendAsCoding,
  onSend,
  onOpenFile,
}: {
  item: TranscriptItem;
  onUsePrompt?: (text: string) => void;
  onResendAsCoding?: (text: string) => void;
  onSend?: (text: string, opts: ChatOptions) => void;
  onOpenFile?: (path: string) => void;
}) {
  switch (item.kind) {
    case "user":
      return <UserMessage agent={item.agent} onResendAsCoding={onResendAsCoding} taskKind={item.taskKind} text={item.text} />;
    case "assistant":
      return <AssistantMessage agent={item.agent} references={item.references} text={item.text} />;
    case "agentPlan":
      return onSend ? <AgentPlanCard agent={item.agent} onSend={onSend} /> : null;
    case "action":
      return <ActionCard item={item.item} />;
    case "note":
      return <NoteLine onOpenFile={onOpenFile} path={item.path} text={item.text} tone={item.tone} />;
    case "undo":
      return <UndoCard changes={item.changes} text={item.text} />;
    case "next":
      return <NextSteps onUse={onUsePrompt} steps={item.steps} />;
    case "clarify":
      return onSend ? <ClarifyCard onOpenFile={onOpenFile} onSend={onSend} planId={item.planId} questions={item.questions} request={item.request} summary={item.summary} /> : null;
    case "plan":
      return onSend ? <PlanCard onOpenFile={onOpenFile} onSend={onSend} plan={item.plan} planId={item.planId} request={item.request} /> : null;
    case "error":
      return <ErrorNote item={item} />;
    case "checks":
      return <ChecksCard items={item.items} text={item.text} />;
  }
}

function activityText(a: Activity): string {
  return a.total ? `${a.label} (${a.done} of ${a.total} files)` : `${a.label}...`;
}

function indicatorTexts(progress: string, stopping: boolean, activity: Activity | null, seed: number): string[] {
  if (stopping) return ["Stopping..."];
  if (activity?.label) return [activityText(activity)];
  return thinkingTexts(progress ? "writing" : "waiting", seed);
}

function ThinkingIndicator({ progress, stopping, activity }: { progress: string; stopping: boolean; activity: Activity | null }) {
  // StreamHub's own work (indexing, scanning for issues): the same indicator, its own text.
  const own = Boolean(activity?.label);
  // One order of the light lines per wait (the indicator mounts when a message starts waiting).
  const [seed] = useState(() => Date.now());
  return (
    <div className="rounded-xl border border-black/10 border-dashed px-3 py-2 dark:border-white/10">
      <AITextLoading
        className="font-semibold text-base"
        containerClassName="justify-start p-0"
        interval={1800}
        texts={indicatorTexts(progress, stopping, activity, seed)}
      />
      {own && activity?.current && <div className="mt-1 truncate font-mono text-muted-foreground text-xs">{activity.current}</div>}
      {progress && !own && (
        <pre className="mt-2 max-h-32 overflow-hidden whitespace-pre-wrap font-mono text-muted-foreground text-xs [mask-image:linear-gradient(to_bottom,transparent,black_40%)]">
          {progress.slice(-700)}
        </pre>
      )}
    </div>
  );
}

/** Chat items shown at first, and added each time you scroll up to the oldest one shown. */
const PAGE = 30;

/** The element that scrolls the chat (the nearest parent with its own scrollbar). */
function scrollParent(el: HTMLElement): HTMLElement | null {
  for (let p = el.parentElement; p; p = p.parentElement) {
    const y = getComputedStyle(p).overflowY;
    if (y === "auto" || y === "scroll") return p;
  }
  return null;
}

const rowKey = (it: TranscriptItem) => (it.kind === "action" ? it.item.id : it.seq);

export function Transcript({
  items,
  busy,
  activity = null,
  progress,
  empty,
  stopping = false,
  onUsePrompt,
  onResendAsCoding,
  onSend,
  onOpenFile,
}: {
  items: TranscriptItem[];
  busy: boolean;
  /** StreamHub's own work besides Copilot (indexing, scanning for issues). */
  activity?: Activity | null;
  progress: string;
  empty?: React.ReactNode;
  stopping?: boolean;
  /** Puts a suggested next step in the message box. */
  onUsePrompt?: (text: string) => void;
  /** Sends a message again as a coding task (when it went as plain chat or project work). */
  onResendAsCoding?: (text: string) => void;
  /** Sends a message with options (answers to questions, plan approval). */
  onSend?: (text: string, opts: ChatOptions) => void;
  /** Opens a project file (PLAN.md from the plan cards). */
  onOpenFile?: (path: string) => void;
}) {
  const endRef = useRef<HTMLDivElement>(null);
  const awaiting = items.some((i) => i.kind === "action" && i.item.status === "awaiting");

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [items.length, busy, awaiting, progress.length > 0]);

  // The newest PAGE items; scrolling up to the oldest one shown loads PAGE more, keeping the place.
  const [shown, setShown] = useState(PAGE);
  const firstKey = items.length ? rowKey(items[0]) : "";
  useEffect(() => setShown(PAGE), [firstKey]); // a new chat, project or cleared history starts over
  const hidden = Math.max(0, items.length - shown);
  const visible = hidden ? items.slice(hidden) : items;
  const topRef = useRef<HTMLDivElement>(null);
  const keepFromBottom = useRef<number | null>(null);
  const loadEarlier = () => {
    const scroller = topRef.current ? scrollParent(topRef.current) : null;
    if (scroller) keepFromBottom.current = scroller.scrollHeight - scroller.scrollTop;
    setShown((n) => n + PAGE);
  };
  useEffect(() => {
    const el = topRef.current;
    if (!hidden || !el) return;
    const io = new IntersectionObserver(([e]) => e.isIntersecting && loadEarlier(), { root: scrollParent(el), rootMargin: "120px 0px 0px 0px" });
    io.observe(el);
    return () => io.disconnect();
  }, [hidden, shown]);
  useLayoutEffect(() => {
    const scroller = topRef.current ? scrollParent(topRef.current) : endRef.current ? scrollParent(endRef.current) : null;
    if (scroller && keepFromBottom.current !== null) scroller.scrollTop = scroller.scrollHeight - keepFromBottom.current;
    keepFromBottom.current = null;
  }, [shown]);

  // A fresh chat shows the welcome view until something happens in it.
  if (!busy && !activity?.label && items.every((i) => i.kind === "note" && i.tone === "info")) return <>{empty}</>;

  return (
    <div className="mx-auto flex w-full max-w-[max(48rem,80%)] flex-col gap-3 px-4 py-6">
      {hidden > 0 && (
        <div className="flex justify-center" ref={topRef}>
          <button className="rounded-md px-2 py-1 text-muted-foreground text-xs hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5" onClick={loadEarlier} type="button">
            {hidden} earlier item{hidden === 1 ? "" : "s"}: scroll up or click to show {Math.min(PAGE, hidden)} more
          </button>
        </div>
      )}
      {visible.map((it) => (
        <TranscriptRow item={it} key={rowKey(it)} onOpenFile={onOpenFile} onResendAsCoding={onResendAsCoding} onSend={onSend} onUsePrompt={onUsePrompt} />
      ))}
      {(busy || activity?.label) && !awaiting && <ThinkingIndicator activity={activity} progress={progress} stopping={stopping} />}
      <div ref={endRef} />
    </div>
  );
}
