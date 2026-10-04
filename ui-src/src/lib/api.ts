// Client for the CCBridge PowerShell server. Every call carries the session token that
// the server injects into index.html, so other pages cannot use the API.

const token =
  document.querySelector<HTMLMetaElement>('meta[name="ccb-token"]')?.content ?? "";

/** The page holds a stale session token (older CCBridge install): reload once (not again within 10 s) to get the current one. */
function reloadOnStaleToken() {
  const last = Number(sessionStorage.getItem("ccb-reload") ?? 0);
  if (Date.now() - last > 10_000) {
    sessionStorage.setItem("ccb-reload", String(Date.now()));
    location.reload();
  }
}

/** The server's error as one line: message, hint, and the error id and code (the id is also in the log). */
function serverErrorText(status: number, data: { error?: string; errId?: string; code?: string; hint?: string }): string {
  const hint = data.hint ? ` ${data.hint}` : "";
  const id = data.errId ? ` (error ${data.errId}${data.code ? `, ${data.code}` : ""})` : "";
  return `${data.error ?? `HTTP ${status}`}${hint}${id}`;
}

async function call<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const res = await fetch(path, {
    method,
    headers: {
      "X-CCB-Token": token,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  // Not JSON (an empty or HTML error page): no details, the status below still reports the failure.
  const data = await res.json().catch(() => ({}));
  if (res.status === 403) {
    reloadOnStaleToken();
    throw new Error("session expired; reload the page");
  }
  if (!res.ok) throw new Error(serverErrorText(res.status, data));
  return data as T;
}

export type Mode = "ask" | "auto" | "plan";

export interface Preview {
  path: string;
  exists: boolean;
  old: string | null;
  new: string | null;
}

export interface TodoItem {
  done: boolean;
  text: string;
}

/** One file an undo restored: the lines that came back (added) and went (removed), and its diff. */
export interface UndoChange {
  path: string;
  /** The step had created the file, so the undo removed it. */
  deleted?: boolean;
  added?: number;
  removed?: number;
  /** Not a text file: restored without line counts. */
  binary?: boolean;
  preview?: Preview | null;
}

export interface AgentEvent {
  seq: number;
  type:
    | "user"
    | "assistant"
    | "action"
    | "action-result"
    | "todos"
    | "done"
    | "status"
    | "error"
    | "project"
    | "checkpoint"
    | "undo"
    | "human-required"
    | "newchat"
    | "fetch"
    | "runbook"
    | "chain"
    | "review"
    | "kind"
    | "clarify"
    | "plan-ready"
    | "next-steps"
    /** Settings > Privacy > Clear chat history: the chat shows nothing from before it. */
    | "history-cleared";
  time: string;
  text?: string;
  uncertain?: number;
  references?: Reference[];
  used?: number;
  max?: number;
  id?: string;
  action?: string;
  target?: string;
  status?: string;
  preview?: Preview | null;
  warning?: string | null;
  error?: string;
  ok?: boolean;
  summary?: string;
  output?: string;
  changed?: boolean;
  /** Who approved or rejected an action: "user" (web app), "api" or "mcp". */
  decidedBy?: string;
  items?: TodoItem[];
  files?: string[];
  /** Failed step: possible reasons and what happens next. */
  reasons?: string[];
  next?: string;
  /** next-steps: follow-ups found in Copilot's last reply, offered as one-click prompts. */
  steps?: string[];
  /** error: id also written to the log, category, what to do, technical detail, CCBridge version. */
  errId?: string;
  code?: string;
  hint?: string;
  detail?: string;
  version?: string;
  name?: string;
  path?: string;
  /** undo: per file what came back and what went. */
  changes?: UndoChange[] | UndoChange;
}

export interface AppState {
  /** location: the folders the project sits in, e.g. ["OneDrive", "CCBridge", "budget tracker"]. */
  project: { name: string; path: string; location?: string[] } | null;
  mode: Mode;
  busy: boolean;
  progress: string;
  copilot: "idle" | "connecting" | "ready" | "error";
  copilotMessage: string;
  throttle: { used: number; max: number };
  credits: { remaining: number; total: number; resetAt: string } | null;
  todos: TodoItem[];
  promptLimit: number;
  workIq: "on" | "off" | "leave";
  workIqActual: string | null;
  workIqAvailable: boolean;
  logLevel: "off" | "info" | "verbose" | "trace";
  /** Installed CCBridge version (version.txt), or git-<sha> for a development copy. */
  version: string;
  /** Every task, newest first, whatever started it (you, an MCP client, ...). */
  queue?: QueueEntry[];
  /** Copilot's response mode: leave (page setting), auto, quick or deep (Think deeper). */
  responseMode?: string;
  responseModeActual?: string | null;
  /** The project's own check from "verify:" in AGENTS.md, if any. */
  verify?: string | null;
  /** Scheduled messages, fetches and runbooks. */
  schedules?: ScheduleItem[];
  /** Set while the queue waits for Copilot's daily limit to reset (local time). */
  pausedUntil?: string | null;
  /** Release tag (v0.1.12) and the commit it was built from (short hash). */
  release?: string;
  commit?: string;
  /** What StreamHub itself is busy with (indexing, scanning for issues); shown like "waiting for Copilot". */
  activity?: Activity | null;
  /** Where the project is served read-only (images in Markdown), e.g. /preview/TOKEN/. */
  previewBase?: string;
  /** Where the app opened: copilot-tab (a tab in the Copilot window), side-by-side or browser. */
  appWindow?: string;
  /** One-time hints already shown, by name (e.g. splitView), with when. */
  hints?: Record<string, string>;
  /** Changes when the project's issue details change (reload the Issues panel). */
  issueStamp?: string;
}

export interface Activity {
  label: string;
  done: number;
  total: number;
  current: string;
  /** true: the background index run (the app stays usable); false: a step of the current task. */
  background: boolean;
}

export type IssueCategory = "error" | "secret" | "health";
export type IssueStatus = "open" | "fixing" | "gave up" | "ignored";

export interface IssueItem {
  id: string;
  path: string;
  line: number;
  category: IssueCategory;
  message: string;
  status: IssueStatus;
  attempts: number;
  note: string;
}

export interface IssueSummary {
  name: string;
  root: string;
  updated: string | null;
  files: number;
  open: Record<IssueCategory, number>;
  fixing: number;
  gaveUp: number;
  ignored: number;
}

export interface IssueReport {
  items: IssueItem[];
  summary: IssueSummary | null;
  projects: IssueSummary[];
  indexing: { running: boolean; last: { files: number; scanned: number; ms: number; at: string } | null; error: string | null };
  settings: { enabled: boolean; autoFix: IssueCategory[]; maxAttempts: number };
}

export interface Reference {
  title: string | null;
  url: string | null;
  kind: string | null;
}

export interface ProjectInfo {
  name: string;
  path: string;
  modified: string;
}

/** How a message is sent: as a coding task, clarify first, plan first, with Think deeper. */
export interface ChatOptions {
  asCoding?: boolean;
  clarify?: boolean;
  planFirst?: boolean;
  /** The original request, when the text adds answers or plan feedback to it. */
  request?: string;
  thinkDeeper?: boolean;
  /** The request's section in PLAN.md, and what to record there. */
  planId?: string;
  answers?: { question: string; answer: string }[];
  skipped?: boolean;
  feedback?: string;
  approve?: boolean;
}

/** A saved code review (reviews/<id>.json) in the list. */
export interface ReviewSummary {
  id: string;
  created: string;
  scopeText: string;
  files: number;
  messages: number;
  high: number;
  medium: number;
  low: number;
  unverified: number;
  report: string;
}

/** One finding: verified = its quoted lines are in the file; general = about the whole project. */
export interface ReviewFinding {
  id: string;
  file: string;
  line: number;
  severity: "high" | "medium" | "low";
  category: string;
  title: string;
  detail: string;
  quote: string;
  suggestion: string;
  status: "verified" | "unverified" | "general";
  reason?: string;
  fixQueueId?: string;
}

export interface ReviewDetail {
  id: string;
  created: string;
  scopeText: string;
  files: string[];
  messages: number;
  overall: string | null;
  findings: ReviewFinding[];
}

/** A schedule: what runs (message, fetch or runbook) and when. */
export interface ScheduleItem {
  id: string;
  title: string;
  kind: "chat" | "fetch" | "runbook" | "chain";
  name: string;
  /** The message, for a scheduled message. */
  text?: string;
  repeat: "once" | "daily" | "weekdays" | "weekly";
  times: string[];
  at: string;
  days: number[];
  when: string;
  enabled: boolean;
  nextRun: string | null;
  lastRun: string | null;
  lastQueueId: string | null;
  project: string | null;
  /** The project's folder (the app shows the schedules of the open project). */
  projectRoot?: string | null;
}

export interface ScheduleSpec {
  kind: "chat" | "fetch" | "runbook" | "chain";
  text?: string;
  name?: string;
  title?: string;
  repeat: "once" | "daily" | "weekdays" | "weekly";
  at?: string;
  days?: number[];
  times?: string[];
}

/** A task in the queue. */
export interface QueueEntry {
  id: string;
  kind: string;
  title: string;
  source: string;
  status: "queued" | "running" | "awaiting" | "done" | "failed" | "cancelled";
  project: string | null;
  /** The project's folder (the app shows the queue of the open project). */
  projectRoot?: string | null;
  created: string;
  started: string | null;
  finished: string | null;
  messages: number;
  summary: string | null;
  error: string | null;
  errId?: string | null;
  resultPath: string | null;
  /** E.g. why it waits, or that a schedule was missed while StreamHub was closed. */
  note?: string | null;
  changed?: string[];
  jobId?: string | null;
}

/** A project runbook (Runbooks/<name>.runbook.md) and its output file. */
export interface RunbookItem {
  name: string;
  title: string;
  path: string;
  output: string;
  lastRun: string | null;
}

/** One step of a chain. */
export interface ChainStep {
  kind: "runbook" | "fetch" | "script";
  target: string;
  /** Files from earlier steps a runbook step gets as data. */
  with?: string[];
  /** Plain arguments of a script step. */
  args?: string;
}

/** A chain (Runbooks/<name>.chain.md): runbooks, fetch prompts and scripts run one after another. */
export interface ChainItem {
  name: string;
  title: string;
  path: string;
  stopOnError: boolean;
  steps: ChainStep[];
  /** Why it cannot run now (unknown runbook, missing script...). */
  problems: string[];
}

export interface RunbookTemplate {
  id: string;
  title: string;
}

/** An adjustable setting (config\harness.local.json). */
export interface Setting {
  key: string;
  group: string;
  label: string;
  help: string;
  /** number / select; toggle (on or off); commands (a list, one per line); info (shown, not changeable). */
  type: "number" | "select" | "toggle" | "commands" | "info";
  value: string | number | boolean | string[] | null;
  default: string | number | boolean | string[] | null;
  custom: boolean;
  min?: number;
  max?: number;
  options?: string[];
}

/**
 * Settings > Sign-in: single sign-on with the Windows work account in StreamHub's Edge profile.
 * profileSso: the switch on Edge's profile page; unavailable = no work account on this PC.
 * copilot: where the Copilot tab is (chat = signed in).
 */
export interface SsoStatus {
  workAccount: boolean;
  profileSso: "on" | "on-auto" | "off" | "managed" | "signed-in-work" | "not-found" | "unavailable" | "edge-not-running" | "unknown";
  /** How Copilot signs in from the next start: StreamHub's profile, or a private session (single sign-on off). */
  signIn?: "single-sign-on" | "private";
  /** The account StreamHub's Edge profile is signed in with. */
  profileAccount?: "work" | "personal" | "none" | "unknown";
  switchLabel?: string;
  copilot: "chat" | "sign-in page" | "no tab" | "edge not running";
  checkedAt?: string;
}

/** A saved fetch prompt (Runbooks/<name>.prompt.md) and its latest answer (Runbooks/Exports/<name>.md). */
export interface FetchItem {
  name: string;
  prompt: string;
  promptPath: string;
  output: string;
  fetchedAt: string | null;
  outputSize: number;
  /** Optional header: web, work or both; the only websites to use; pages read and added as data. */
  sources?: string;
  sites?: string;
  pages?: string;
}

/** The web fields of a fetch prompt when it is saved. */
export interface FetchWeb {
  sources: "" | "web" | "work" | "both";
  sites: string;
  pages: string;
}

export interface FileInfo {
  path: string;
  size: number;
  /** Lines added / removed since the project was opened (only for changed files). */
  added?: number;
  removed?: number;
  /** Created since the project was opened (shown as new, also without lines to count). */
  created?: boolean;
}

// Whatever the server (and Copilot behind it) sends, the UI only ever renders strings here.
const TEXT_FIELDS = ["text", "target", "summary", "output", "error", "warning", "status", "action", "id", "decidedBy", "errId", "code", "hint", "detail", "version"] as const;

function asText(v: unknown): string | undefined {
  if (v === null || v === undefined) return undefined;
  return typeof v === "string" ? v : typeof v === "object" ? JSON.stringify(v) : String(v);
}

/** A list of non-empty strings. */
function asTexts(list: unknown[]): string[] {
  return list.map((s) => asText(s) ?? "").filter(Boolean);
}

const asArray = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

/** How each structured field is cleaned when an event has it. */
const FIELD_RULES: Record<string, (v: unknown) => unknown> = {
  references: (v) =>
    asArray(v)
      .filter((r): r is Reference => !!r && typeof r === "object")
      .map((r) => ({ title: asText(r.title) ?? null, url: asText(r.url) ?? null, kind: asText(r.kind) ?? null })),
  items: asArray,
  files: asArray,
  steps: (v) => asTexts(asArray(v)),
  reasons: (v) => asTexts(Array.isArray(v) ? v : [v]), // a single reason becomes a list
  next: asText,
};

export function normalizeEvent(raw: AgentEvent): AgentEvent {
  const e = { ...raw } as Record<string, unknown>;
  for (const k of TEXT_FIELDS) if (k in e) e[k] = asText(e[k]);
  for (const [k, clean] of Object.entries(FIELD_RULES)) if (e[k] !== undefined) e[k] = clean(e[k]);
  return e as unknown as AgentEvent;
}

/** Reports a page error to the CCBridge log (best effort). */
export function reportClientError(message: string, detail: Record<string, unknown> = {}) {
  fetch("/api/clientlog", {
    method: "POST",
    headers: { "X-CCB-Token": token, "Content-Type": "application/json" },
    body: JSON.stringify({ message, ...detail }),
  }).catch(() => {}); // the log is out of reach: reporting that would only fail the same way
}

/** A list from the server; a single object (PowerShell can unroll a list of one) becomes a list. */
function asList<T>(v: T[] | T | null | undefined): T[] {
  return Array.isArray(v) ? v : v && typeof v === "object" ? [v] : [];
}

export const api = {
  poll: (after: number) =>
    call<{ events: AgentEvent[]; state: AppState }>("GET", `/api/poll?after=${after}`).then((r) => ({
      ...r,
      events: (Array.isArray(r.events) ? r.events : []).map(normalizeEvent),
    })),
  projects: () => call<{ root: string; projects: ProjectInfo[] }>("GET", "/api/projects"),
  createProject: (name: string) => call<{ ok: boolean; path: string }>("POST", "/api/projects", { name }),
  openProject: (path: string) => call<{ ok: boolean }>("POST", "/api/project/open", { path }),
  files: () => call<{ files: FileInfo[] }>("GET", "/api/files"),
  file: (path: string) =>
    call<{ path: string; text: string }>("GET", `/api/file?path=${encodeURIComponent(path)}`),
  chat: (text: string, opts: ChatOptions = {}) => call<{ ok: boolean }>("POST", "/api/chat", { text, ...opts }),
  setResponseMode: (value: string) => call<{ ok: boolean }>("POST", "/api/response-mode", { value }),
  fetchList: () => call<{ items: FetchItem[] }>("GET", "/api/fetch").then((r) => (Array.isArray(r.items) ? r.items : [])),
  saveFetch: (name: string, prompt: string, web?: FetchWeb) => call<{ ok: boolean; item: FetchItem }>("POST", "/api/fetch", { name, prompt, ...(web ?? {}) }),
  runFetch: (name: string) => call<{ ok: boolean }>("POST", "/api/fetch/run", { name }),
  runbooks: () =>
    call<{ runbooks: RunbookItem[]; templates: RunbookTemplate[] }>("GET", "/api/runbooks").then((r) => ({
      runbooks: asList(r.runbooks),
      templates: asList(r.templates),
    })),
  createRunbook: (template: string, name: string) => call<{ ok: boolean; item: RunbookItem }>("POST", "/api/runbooks", { template, name }),
  runRunbook: (name: string) => call<{ ok: boolean }>("POST", "/api/runbooks/run", { name }),
  chains: () =>
    call<{ chains: ChainItem[]; scripts: string[] }>("GET", "/api/chains").then((r) => ({
      chains: asList(r.chains).map((c) => ({ ...c, steps: asList(c.steps), problems: asList(c.problems) })),
      scripts: asList(r.scripts),
    })),
  createChain: (name: string) => call<{ ok: boolean }>("POST", "/api/chains", { name }),
  runChain: (name: string) => call<{ ok: boolean }>("POST", "/api/chains/run", { name }),
  approve: (id: string, decision: "approve" | "reject", note = "") =>
    call<{ ok: boolean }>("POST", "/api/approve", { id, decision, note, by: "user" }),
  setMode: (mode: Mode) => call<{ ok: boolean }>("POST", "/api/mode", { mode }),
  newChat: () => call<{ ok: boolean }>("POST", "/api/newchat"),
  undo: () => call<{ ok: boolean }>("POST", "/api/undo"),
  stop: () => call<{ ok: boolean }>("POST", "/api/stop"),
  connect: () => call<{ ok: boolean }>("POST", "/api/connect"),
  cancelQueued: (id: string) => call<{ ok: boolean }>("POST", "/api/queue/cancel", { id }),
  resumeQueue: () => call<{ ok: boolean }>("POST", "/api/queue/resume"),
  reviewEstimate: (scope: string, paths: string[]) =>
    call<{ files: number; skipped: number; batches: number; messages: number; scopeText: string }>("POST", "/api/reviews/estimate", { scope, paths }),
  runReview: (scope: string, paths: string[], focus: string[]) => call<{ ok: boolean; id: string }>("POST", "/api/reviews/run", { scope, paths, focus }),
  reviews: () => call<{ reviews: ReviewSummary[] }>("GET", "/api/reviews").then((r) => (Array.isArray(r.reviews) ? r.reviews : r.reviews ? [r.reviews as unknown as ReviewSummary] : [])),
  getReview: (id: string) =>
    call<{ review: ReviewDetail }>("POST", "/api/reviews/get", { id }).then((r) => ({
      ...r.review,
      files: asList(r.review.files),
      findings: asList(r.review.findings),
    })),
  fixFindings: (id: string, ids: string[]) => call<{ ok: boolean; tasks: number }>("POST", "/api/reviews/fix", { id, ids }),
  createSchedule: (spec: ScheduleSpec) => call<{ ok: boolean; id: string }>("POST", "/api/schedules", spec),
  editSchedule: (id: string, spec: ScheduleSpec) => call<{ ok: boolean }>("POST", "/api/schedules/edit", { id, ...spec }),
  updateSchedule: (id: string, change: { enabled?: boolean }) => call<{ ok: boolean }>("POST", "/api/schedules/update", { id, ...change }),
  deleteSchedule: (id: string) => call<{ ok: boolean }>("POST", "/api/schedules/delete", { id }),
  runSchedule: (id: string) => call<{ ok: boolean }>("POST", "/api/schedules/run", { id }),
  showProject: () => call<{ ok: boolean }>("POST", "/api/project/show"),
  issues: () =>
    call<IssueReport>("GET", "/api/issues").then((r) => ({
      ...r,
      items: asList(r.items),
      projects: asList(r.projects),
      settings: { ...r.settings, autoFix: asList(r.settings?.autoFix) },
    })),
  reindexIssues: (force = false) => call<{ ok: boolean; started: boolean }>("POST", "/api/issues/reindex", { force }),
  fixIssues: (paths: string[], categories: IssueCategory[]) => call<{ ok: boolean; queued: number; issues: number }>("POST", "/api/issues/fix", { paths, categories }),
  ignoreIssues: (ids: string[], undo = false) => call<{ ok: boolean }>("POST", "/api/issues/ignore", { ids, undo }),
  clearHistory: () => call<{ ok: boolean }>("POST", "/api/history/clear"),
  markHintShown: (name: string) => call<{ ok: boolean }>("POST", "/api/hints", { name }),
  resetSettings: () =>
    call<{ ok: boolean; changed: string[]; settings: Setting[] }>("POST", "/api/settings/reset").then((r) => ({ ...r, changed: asList(r.changed), settings: asList(r.settings) })),
  settings: () => call<{ settings: Setting[] }>("GET", "/api/settings").then((r) => (Array.isArray(r.settings) ? r.settings : [])),
  setSetting: (key: string, value: Setting["value"]) =>
    call<{ ok: boolean; settings: Setting[] }>("POST", "/api/settings", { key, value }).then((r) => ({ ...r, settings: Array.isArray(r.settings) ? r.settings : [] })),
  ssoStatus: () => call<{ status: SsoStatus }>("GET", "/api/sso").then((r) => r.status),
  setSso: (on: boolean) => call<{ ok: boolean; result: string; status: SsoStatus }>("POST", "/api/sso", { on }),
  ssoSetup: () => call<{ ok: boolean; result: string; logFile: string; status: SsoStatus }>("POST", "/api/sso/setup"),
  openSsoSettings: () => call<{ ok: boolean }>("POST", "/api/sso/open"),
  setWorkIq: (value: "on" | "off" | "leave") => call<{ ok: boolean }>("POST", "/api/workiq", { value }),
  setLogging: (level: "off" | "info" | "verbose" | "trace") => call<{ ok: boolean }>("POST", "/api/logging", { level }),
  diagnostics: () => call<{ ok: boolean; path: string; fullPath: string }>("POST", "/api/diagnostics"),
  showDiagnostics: (path: string) => call<{ ok: boolean }>("POST", "/api/diagnostics/show", { path }),
  /** Uploads a file into the project's read-only Source/ folder, reporting progress 0-100. */
  uploadSource: (file: File, onProgress: (percent: number) => void) =>
    new Promise<void>((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open("POST", `/api/source?name=${encodeURIComponent(file.name)}`);
      xhr.setRequestHeader("X-CCB-Token", token);
      xhr.setRequestHeader("Content-Type", "application/octet-stream");
      xhr.upload.onprogress = (e) => e.lengthComputable && onProgress((e.loaded / e.total) * 100);
      xhr.onload = () => {
        if (xhr.status === 200) resolve();
        else {
          let msg = `HTTP ${xhr.status}`;
          try {
            msg = JSON.parse(xhr.responseText).error ?? msg;
          } catch {
            // Not JSON: keep "HTTP <status>" as the message.
          }
          reject(new Error(msg));
        }
      };
      xhr.onerror = () => reject(new Error("Upload failed"));
      xhr.send(file);
    }),
};
