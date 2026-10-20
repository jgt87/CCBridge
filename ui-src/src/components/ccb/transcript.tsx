import { openExternal } from "@/lib/links";
import { IntakeCard } from "./intake-card";
import type { IntakeGroup } from "@/lib/api";
import { AlertCircle, CheckCircle2, Hand, Info, Link2, RotateCcw, User } from "lucide-react";
import { AgentPlanCard, ClarifyCard, type ClarifyQuestion, PlanCard, type PlanVariant } from "./plan-cards";
import type { ChatOptions } from "@/lib/api";
import { useEffect, useMemo, useRef, useState } from "react";
import { RunLiveContext, type RunLive, type RunLiveView, type RunWindowState } from "@/lib/run-live";
import { MarkdownView } from "./markdown-view";
import { useFollowBottom, usePagedItems } from "@/hooks/use-transcript-scroll";
import { useNodeInstall } from "@/hooks/use-node-install";
import { type NodeInstall, packagesNotes } from "@/lib/packages-card";
import AITextLoading from "@/components/kokonutui/ai-text-loading";
import type { Activity, AgentEvent, CheckFinding, Preview, Reference, UndoChange, WorkStatus } from "@/lib/api";
import { ChecksCard } from "./checks-card";
import { SetupChoiceCard, type SetupChoiceItem } from "./project-setup";
import { UndoCard } from "./undo-card";
import { stripActionBlocks } from "@/lib/diff";
import { formatDuration, rowTime } from "@/lib/row-time";
import { workView } from "@/lib/work-status";
import { activityTexts, thinkingTexts, writesStyles } from "@/lib/thinking-texts";
import { cn } from "@/lib/utils";
import { ActionCard, LiveConsole, type ActionItem } from "./action-card";
import GradientButton from "@/components/kokonutui/gradient-button";

type NoteTone = "info" | "error" | "done" | "undo" | "human";

/** When an item happened (its first event) and, for an action, when its result came in. */
type Stamp = { time?: string; at?: string; endAt?: string };

export type TranscriptItem = Stamp &
  (
  | { kind: "user"; seq: number; text: string; taskKind?: string; agent?: string }
  | { kind: "assistant"; seq: number; text: string; uncertain: number; references: Reference[]; agent?: string }
  | { kind: "agentPlan"; seq: number; agent: string }
  | { kind: "runbookChoice"; seq: number; name: string; title: string; request: string; restored: boolean }
  | SetupChoiceItem
  | { kind: "packages"; seq: number; folder: string; text: string; npm: boolean; restored: boolean }
  | { kind: "intake"; seq: number; text: string; groups: IntakeGroup[]; restored: boolean }
  | { kind: "unfinished"; seq: number; text: string; findings: string[]; continueText: string; restored: boolean }
  | { kind: "action"; seq: number; item: ActionItem }
  | { kind: "note"; seq: number; tone: NoteTone; text: string; path?: string }
  | { kind: "undo"; seq: number; text: string; changes: UndoChange[] }
  | { kind: "next"; seq: number; steps: string[] }
  | { kind: "clarify"; seq: number; request: string; questions: ClarifyQuestion[]; summary?: string; planId?: string }
  | { kind: "plan"; seq: number; request: string; plan: string; planId?: string; variant?: PlanVariant }
  | { kind: "error"; seq: number; text: string; time: string; errId?: string; code?: string; hint?: string; detail?: string; version?: string }
  | { kind: "checks"; seq: number; text: string; items: CheckFinding[] }
  );

// --- Building the transcript from events ------------------------------------------------

interface BuildContext {
  items: TranscriptItem[];
  actions: Map<string, ActionItem>;
  /** When each action's result came in (its duration in the time column). */
  ends: Map<string, string>;
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
    allowOptions: e.allowOptions ? (Array.isArray(e.allowOptions) ? e.allowOptions : [e.allowOptions]) : existing?.allowOptions,
    error: e.error ?? existing?.error,
    target: e.target ?? existing?.target ?? "",
    by: (e as AgentEvent & { by?: string }).by ?? existing?.by,
    window: e.window ?? existing?.window,
  };
  ctx.actions.set(e.id!, next);
  if (!existing) ctx.items.push({ kind: "action", seq: e.seq, item: next });
}

/** An action-result event updates the card of its action (results without a card are ignored). */
function mergeActionResult(e: AgentEvent, ctx: BuildContext) {
  const existing = ctx.actions.get(e.id!);
  if (!existing) return;
  if (e.at) ctx.ends.set(e.id!, e.at);
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
  "task-unfinished": (e, ctx) =>
    ctx.items.push({
      kind: "unfinished",
      seq: e.seq,
      text: e.text ?? "",
      findings: Array.isArray((e as { findings?: unknown }).findings) ? ((e as { findings?: string[] }).findings ?? []) : [],
      continueText: e.continueText ?? "",
      restored: Boolean(e.restored),
    }),
  "files-intake": (e, ctx) => {
    const list = (v: unknown) => (Array.isArray(v) ? v : v ? [v] : []);
    const groups = list(e.groups).map((g: IntakeGroup) => ({ ...g, files: list(g.files) as string[], options: list(g.options) as IntakeGroup["options"] }));
    ctx.items.push({ kind: "intake", seq: e.seq, text: e.text ?? "", groups, restored: Boolean(e.restored) });
  },
  "packages-needed": (e, ctx) =>
    ctx.items.push({ kind: "packages", seq: e.seq, folder: e.folder ?? "", text: e.text ?? "", npm: e.npm !== false, restored: Boolean(e.restored) }),
  "setup-choice": (e, ctx) =>
    ctx.items.push({
      kind: "setupChoice",
      seq: e.seq,
      request: e.request ?? "",
      choices: Array.isArray(e.choices) ? e.choices : e.choices ? [e.choices] : [],
      live: Boolean(e.live),
      suggest: e.suggest ?? "",
      clarify: Boolean(e.clarify),
      restored: Boolean(e.restored),
    }),
  "runbook-choice": (e, ctx) =>
    ctx.items.push({ kind: "runbookChoice", seq: e.seq, name: e.name ?? "", title: e.title ?? "", request: e.request ?? "", restored: Boolean(e.restored) }),
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
    const x = e as AgentEvent & { request?: string; plan?: string; planId?: string; proposal?: boolean; unfinished?: boolean };
    const variant: PlanVariant = x.unfinished ? "unfinished" : x.proposal ? "proposal" : "plan";
    if (x.plan) ctx.items.push({ kind: "plan", seq: e.seq, request: x.request ?? "", plan: x.plan, planId: x.planId || undefined, variant });
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
  const ctx: BuildContext = { items: [], actions: new Map(), ends: new Map() };
  for (const e of events) {
    const from = ctx.items.length;
    (HANDLERS[e.type] ?? addNote)(e, ctx);
    // New items carry the time of the event that made them.
    for (let i = from; i < ctx.items.length; i++) if (!ctx.items[i].at) ctx.items[i] = { ...ctx.items[i], time: ctx.items[i].time ?? e.time, at: e.at };
  }
  // Re-create action items so React sees the merged state.
  return ctx.items.map((it) => (it.kind === "action" ? { ...it, item: { ...ctx.actions.get(it.item.id)! }, endAt: ctx.ends.get(it.item.id) } : it));
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
        const cls = "inline-flex max-w-72 items-center gap-1 truncate rounded-md bg-(--kit-surface-2) px-2 py-0.5 text-foreground/80";
        return r.url ? (
          <a className={`${cls} hover:bg-(--kit-surface-2)`} href={r.url} key={i} onClick={openExternal} rel="noreferrer" target="_blank" title={label}>
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
  error: { icon: <AlertCircle className="h-4 w-4" />, cls: "text-(--kit-error)" },
  done: { icon: <CheckCircle2 className="h-4 w-4" />, cls: "text-foreground" },
  undo: { icon: <RotateCcw className="h-4 w-4" />, cls: "text-muted-foreground" },
  human: {
    icon: <Hand className="h-4 w-4" />,
    cls: "rounded-lg border border-(--kit-border-strong) bg-(--kit-surface-2) px-3 py-2 font-medium text-foreground",
  },
};

const KIND_LABEL: Record<string, string> = { chat: "sent as plain chat", project: "sent as project work (no code instructions)", assistant: "sent as a Microsoft 365 question" };

function UserMessage({ text, taskKind, agent, onResendAsCoding }: { text: string; taskKind?: string; agent?: string; onResendAsCoding?: (text: string) => void }) {
  const label = taskKind ? KIND_LABEL[taskKind] : undefined;
  return (
    <div className="flex flex-col items-end gap-1">
      {agent && <span className="rounded-full border border-(--kit-border-strong) px-2 py-0.5 text-muted-foreground text-xs">to {agent}</span>}
      <div className="flex max-w-[85%] items-start gap-2 rounded-2xl rounded-tr-sm bg-(--kit-surface-2) px-4 py-2.5 text-sm">
        <span className="whitespace-pre-wrap">{text}</span>
        <User className="mt-0.5 h-3.5 w-3.5 shrink-0 opacity-50" />
      </div>
      {label && onResendAsCoding && (
        <div className="flex items-center gap-2 text-muted-foreground text-xs">
          <span>{label}</span>
          <button className="rounded-md px-1.5 py-0.5 hover:bg-(--kit-surface-2) hover:text-foreground" onClick={() => onResendAsCoding(text)} title="Send it again with the coding instructions and the project's files" type="button">
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
        <span className="mb-1 inline-block rounded-full border border-(--kit-border-strong) px-2 py-0.5 text-muted-foreground text-xs" title={`Answered by Copilot's ${agent} agent (from Copilot's reply)`}>
          {agent}
        </span>
      )}
      {visible && <Markdown text={visible} />}
      {references.length > 0 && <Sources refs={references} />}
    </div>
  );
}

/** A message named a runbook without saying to run it: run it, or send the message to Copilot. */
function RunbookChoiceCard({ item, onSend }: { item: Extract<TranscriptItem, { kind: "runbookChoice" }>; onSend?: (text: string, opts: ChatOptions) => void }) {
  const [chosen, setChosen] = useState<"" | "run" | "copilot">("");
  const label = item.title ? `'${item.title}' (${item.name})` : item.name;
  if (item.restored || chosen) {
    return (
      <div className="flex items-start gap-2 px-1 text-muted-foreground text-sm">
        <Info className="mt-0.5 h-4 w-4" />
        <span>{chosen === "run" ? `Running runbook ${label}.` : chosen === "copilot" ? "Sent to Copilot." : `Your message named runbook ${label}.`}</span>
      </div>
    );
  }
  const run = () => {
    setChosen("run");
    // The API client is loaded here: it reads the page's session token when loaded.
    import("@/lib/api").then(({ api }) => api.runRunbook(item.name)).catch(() => setChosen(""));
  };
  const toCopilot = () => {
    setChosen("copilot");
    onSend?.(item.request, { noRunbook: true });
  };
  const btn = "kit-btn kit-btn--ghost h-10";
  return (
    <div className="kit-panel space-y-2 px-3 py-2 text-sm">
      <div>Your message names runbook {label}. Run it now, or send the message to Copilot (for example to change the runbook)?</div>
      <div className="flex flex-wrap items-center gap-2">
        <GradientButton className="h-10 min-w-44" label="Run it" onClick={run} variant="neutral" />
        <button className={btn} disabled={!onSend} onClick={toCopilot} type="button">
          Send to Copilot
        </button>
      </div>
    </div>
  );
}

/** A task that changed files ended without "done": what StreamHub's checks found, and Continue. */
function UnfinishedCard({ item, onSend }: { item: Extract<TranscriptItem, { kind: "unfinished" }>; onSend?: (text: string, opts: ChatOptions) => void }) {
  const [sent, setSent] = useState(false);
  return (
    <div className="kit-panel space-y-2 px-3 py-2 text-sm">
      <div className="flex items-start gap-2">
        <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
        <span>{item.text}</span>
      </div>
      {item.findings.length > 0 && (
        <ul className="ml-6 list-disc space-y-0.5 text-muted-foreground text-xs">
          {item.findings.map((f, i) => (
            <li className="break-words" key={i}>
              {f}
            </li>
          ))}
        </ul>
      )}
      {!item.restored && (
        <div className="flex flex-wrap items-center gap-2">
          <GradientButton className="h-10 min-w-44" disabled={sent || !onSend || !item.continueText} label={sent ? "Sent to Copilot" : "Continue"} onClick={() => { setSent(true); onSend?.(item.continueText, { asCoding: true }); }} variant="neutral" />
        </div>
      )}
    </div>
  );
}

/** A package.json lists packages that are not installed: npm install on a click (never by itself). */
function PackagesCard({ item }: { item: Extract<TranscriptItem, { kind: "packages" }> }) {
  const [state, setState] = useState<"" | "started" | "later" | "failed">("");
  // Without npm the card offers Node.js (which brings npm) first; once it is in, npm install can run.
  const { npm, node, nodeMessage, installNode } = useNodeInstall(item.npm);
  if (item.restored || state === "later" || state === "started") {
    return (
      <div className="flex items-start gap-2 px-1 text-muted-foreground text-sm">
        <Info className="mt-0.5 h-4 w-4" />
        <span>{state === "started" ? "npm install started." : `This project needs its packages: ${item.text}. Settings > This computer > Project packages runs npm install.`}</span>
      </div>
    );
  }
  const install = () => {
    setState("started");
    import("@/lib/api").then(({ api }) => api.installPackages(item.folder)).catch(() => setState("failed"));
  };
  return (
    <div className="kit-panel space-y-2 px-3 py-2 text-sm">
      <div>This project needs its packages: {item.text}. Install them with npm now? It downloads them from npm's registry and runs their install steps.</div>
      {packagesNotes(npm, node, nodeMessage, state === "failed").map((n) => (
        <div className={n.error ? "kit-error-text" : "text-muted-foreground text-xs"} key={n.text}>
          {n.text}
        </div>
      ))}
      <PackagesButtons node={node} npm={npm} onInstall={install} onInstallNode={installNode} onLater={() => setState("later")} />
    </div>
  );
}

/** The packages card's buttons: Install Node.js while npm is missing, Run npm install once it is there, Not now. */
function PackagesButtons({ npm, node, onInstall, onInstallNode, onLater }: { npm: boolean; node: NodeInstall; onInstall: () => void; onInstallNode: () => void; onLater: () => void }) {
  const btn = "kit-btn kit-btn--ghost kit-btn--sm";
  const nodeBusy = node === "installing" || node === "pending";
  return (
    <div className="flex flex-wrap items-center gap-2">
      {!npm && node !== "done" && <GradientButton className="h-10 min-w-44" disabled={nodeBusy} label="Install Node.js" onClick={onInstallNode} variant="neutral" />}
      {npm ? (
        <GradientButton className="h-10 min-w-44" label="Run npm install" onClick={onInstall} variant="neutral" />
      ) : (
        <button className={cn(btn, "h-10 px-3 text-sm")} disabled type="button">
          Run npm install
        </button>
      )}
      <button className={cn(btn, "h-10 px-3 text-sm")} onClick={onLater} type="button">
        Not now
      </button>
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
        <button className="kit-link min-w-0 whitespace-pre-wrap text-left no-underline [overflow-wrap:anywhere] hover:underline" onClick={() => onOpenFile(path)} title={`Open ${path}`} type="button">
          {text}
        </button>
      ) : (
        <span className="min-w-0 whitespace-pre-wrap [overflow-wrap:anywhere]">{text}</span>
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
        {item.code && <span className="kit-badge rounded-(--kit-radius-sm) font-mono font-normal">{item.code}</span>}
        {item.hint && <span>{item.hint}</span>}
        <button className="kit-link no-underline hover:underline" onClick={copy} type="button">
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
    <div className="kit-panel border-dashed px-3 py-2">
      <div className="mb-1.5 text-muted-foreground text-xs">Suggested next steps (click one to put it in the message box)</div>
      <div className="flex flex-col gap-1">
        {steps.map((s, i) => (
          <button
            className="w-full rounded-md px-2 py-1 text-left text-sm hover:bg-(--kit-surface-2) disabled:opacity-50"
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

/** The time column next to an item: when it happened, and how long a finished action took. */
function RowTimeLabel({ item }: { item: TranscriptItem }) {
  const t = rowTime(item.time, item.at, item.kind === "action" ? item.endAt : undefined);
  if (!t) return <span className="w-16 shrink-0" />;
  return (
    <span className="w-16 shrink-0 pt-1 text-right text-[11px] text-muted-foreground tabular-nums leading-tight" title={t.title}>
      <time dateTime={item.at}>{t.label}</time>
      {t.took && <span className="block opacity-80">{t.took}</span>}
    </span>
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
    case "runbookChoice":
      return <RunbookChoiceCard item={item} onSend={onSend} />;
    case "setupChoice":
      return <SetupChoiceCard item={item} onSend={onSend} />;
    case "packages":
      return <PackagesCard item={item} />;
    case "intake":
      return <IntakeCard groups={item.groups} restored={item.restored} text={item.text} />;
    case "unfinished":
      return <UnfinishedCard item={item} onSend={onSend} />;
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
      return onSend ? <PlanCard onOpenFile={onOpenFile} onSend={onSend} plan={item.plan} planId={item.planId} request={item.request} variant={item.variant} /> : null;
    case "error":
      return <ErrorNote item={item} />;
    case "checks":
      return <ChecksCard items={item.items} text={item.text} />;
  }
}

function activityText(a: Activity): string {
  return a.total ? `${a.label} (${a.done} of ${a.total} files)` : `${a.label}...`;
}

function indicatorTexts(progress: string, stopping: boolean, activity: Activity | null, seed: number, look: boolean): string[] {
  if (stopping) return ["Stopping..."];
  if (activity?.label) return activityTexts(activityText(activity), activity.kind, seed);
  return thinkingTexts(progress ? "writing" : "waiting", seed, look || writesStyles(progress));
}

/** The clock for the waiting card: re-renders every second while it shows. */
function useNow(stepMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), stepMs);
    return () => window.clearInterval(t);
  }, [stepMs]);
  return now;
}

/** Under the rotating text: what StreamHub does now and since when, the task so far, the last sign of
 *  life, a warning with Show Copilot and Stop when nothing happened for minutes, and the last steps. */
function WorkStatusLines({ work, onStop, onShowCopilot, stopping }: { work: WorkStatus; onStop?: () => void; onShowCopilot?: () => Promise<boolean>; stopping: boolean }) {
  const now = useNow();
  const v = workView(work, now);
  const [shown, setShown] = useState<"" | "shown" | "missing">("");
  const showCopilot = () => onShowCopilot?.().then((ok) => setShown(ok ? "shown" : "missing"), () => setShown("missing"));
  return (
    <div className="mt-1.5 min-w-0 space-y-0.5 [overflow-wrap:anywhere]">
      <div className="text-foreground/80 text-sm">{v.phase}</div>
      <div className="text-muted-foreground text-xs tabular-nums">
        {v.detail}
        {v.detail ? " · " : ""}
        {v.sign}
      </div>
      {v.quiet && (
        <div className="kit-notice kit-notice--warn mt-2 text-xs" role="status">
          <div>
            Nothing new for {formatDuration(v.quietMs)}. {v.quietText}
          </div>
          <div className="mt-1.5 flex flex-wrap items-center gap-2">
            {onShowCopilot && (
              <button className="kit-btn kit-btn--sm" onClick={showCopilot} type="button">
                Show Copilot
              </button>
            )}
            {onStop && (
              <button className="kit-btn kit-btn--sm kit-btn--ghost" disabled={stopping} onClick={onStop} type="button">
                Stop
              </button>
            )}
            {shown === "missing" && <span className="text-muted-foreground">Copilot's tab was not found in StreamHub's Edge.</span>}
          </div>
        </div>
      )}
      {v.steps.length > 0 && (
        <details className="mt-1.5">
          <summary className="cursor-pointer text-muted-foreground text-xs hover:text-foreground">Activity log ({v.steps.length})</summary>
          <ol className="mt-1 space-y-0.5 text-xs">
            {[...v.steps].reverse().map((s, i) => (
              <li className="flex gap-2" key={`${s.at}-${i}`}>
                <time className="shrink-0 text-muted-foreground tabular-nums" dateTime={s.at}>
                  {s.at.slice(11, 19)}
                </time>
                <span className="min-w-0">{s.text}</span>
              </li>
            ))}
          </ol>
        </details>
      )}
    </div>
  );
}

function ThinkingIndicator({
  progress,
  stopping,
  activity,
  look,
  work,
  onStop,
  onShowCopilot,
}: {
  progress: string;
  stopping: boolean;
  activity: Activity | null;
  look: boolean;
  work: WorkStatus | null;
  onStop?: () => void;
  onShowCopilot?: () => Promise<boolean>;
}) {
  // StreamHub's own work (indexing, scanning for issues): the same indicator, its own text.
  const own = Boolean(activity?.label);
  // One order of the light lines per wait (the indicator mounts when a message starts waiting).
  const [seed] = useState(() => Date.now());
  return (
    <div className="kit-panel min-w-0 overflow-hidden border-dashed px-3 py-2">
      <AITextLoading
        className="font-semibold text-base"
        containerClassName="justify-start p-0"
        interval={1800}
        texts={indicatorTexts(progress, stopping, activity, seed, look)}
      />
      {work && <WorkStatusLines onShowCopilot={onShowCopilot} onStop={onStop} stopping={stopping} work={work} />}
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

const rowKey = (it: TranscriptItem) => (it.kind === "action" ? it.item.id : it.seq);

/** A run without a card of its own (the project's verify command, tests): its console goes under the indicator. */
const runWithoutCard = (items: TranscriptItem[], runLive: RunLive | null) =>
  runLive && !items.some((i) => i.kind === "action" && i.item.id === runLive.id) ? runLive : null;

export function Transcript({
  items,
  busy,
  activity = null,
  look = false,
  runLive = null,
  runWindows = [],
  progress,
  empty,
  stopping = false,
  work = null,
  onStop,
  onShowCopilot,
  onUsePrompt,
  onResendAsCoding,
  onSend,
  onOpenFile,
}: {
  items: TranscriptItem[];
  busy: boolean;
  /** The running task's status (WorkStatus.psm1), shown under the rotating text. */
  work?: WorkStatus | null;
  /** Stops the running task (the quiet warning's Stop). */
  onStop?: () => void;
  /** Brings Copilot's tab to the front; true when it was found. */
  onShowCopilot?: () => Promise<boolean>;
  /** StreamHub's own work besides Copilot (indexing, scanning for issues). */
  activity?: Activity | null;
  /** The turn is about how something looks: the indicator's art lines. */
  look?: boolean;
  /** The command running now (live output on its card) and commands running in a console window. */
  runLive?: RunLive | null;
  runWindows?: RunWindowState[];
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
  const contentRef = useRef<HTMLDivElement>(null);
  const awaiting = items.some((i) => i.kind === "action" && i.item.status === "awaiting");
  // A fresh chat shows the welcome view until something happens in it.
  const showEmpty = !busy && !activity?.label && items.every((i) => i.kind === "note" && i.tone === "info");
  useFollowBottom(contentRef, showEmpty, items.length, items[items.length - 1]?.kind === "user", awaiting);
  const { hidden, visible, topRef, loadEarlier } = usePagedItems(items, items.length ? rowKey(items[0]) : "", PAGE, endRef);

  const live = useMemo<RunLiveView>(() => ({ live: runLive, windows: runWindows }), [runLive, runWindows]);
  const liveWithoutCard = runWithoutCard(items, runLive);
  // The waiting card, unless a step waits for approval (its card says what happens next).
  const waiting = (busy || Boolean(activity?.label)) && !awaiting;

  if (showEmpty) return <>{empty}</>;

  return (
    <RunLiveContext.Provider value={live}>
    <div className="mx-auto flex w-full max-w-[max(48rem,80%)] flex-col gap-3 px-4 py-6" ref={contentRef}>
      {hidden > 0 && (
        <div className="flex justify-center" ref={topRef}>
          <button className="rounded-md px-2 py-1 text-muted-foreground text-xs hover:bg-(--kit-surface-2) hover:text-foreground" onClick={loadEarlier} type="button">
            {hidden} earlier item{hidden === 1 ? "" : "s"}: scroll up or click to show {Math.min(PAGE, hidden)} more
          </button>
        </div>
      )}
      {visible.map((it) => (
        <div className="flex min-w-0 items-start gap-2" key={rowKey(it)}>
          <div className="min-w-0 flex-1">
            <TranscriptRow item={it} onOpenFile={onOpenFile} onResendAsCoding={onResendAsCoding} onSend={onSend} onUsePrompt={onUsePrompt} />
          </div>
          <RowTimeLabel item={it} />
        </div>
      ))}
      {/* The same width as the items above, beside an empty time column. */}
      {waiting || liveWithoutCard ? (
        <div className="flex min-w-0 items-start gap-2">
          <div className="flex min-w-0 flex-1 flex-col gap-3">
            {waiting && <ThinkingIndicator activity={activity} look={look} onShowCopilot={onShowCopilot} onStop={onStop} progress={progress} stopping={stopping} work={work} />}
            {liveWithoutCard && <LiveConsole live={liveWithoutCard} />}
          </div>
          <span className="w-16 shrink-0" />
        </div>
      ) : null}
      <div ref={endRef} />
    </div>
    </RunLiveContext.Provider>
  );
}
