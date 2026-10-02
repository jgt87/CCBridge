// Client for the CCBridge PowerShell server. Every call carries the session token that
// the server injects into index.html, so other pages cannot use the API.

const token =
  document.querySelector<HTMLMetaElement>('meta[name="ccb-token"]')?.content ?? "";

async function call<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const res = await fetch(path, {
    method,
    headers: {
      "X-CCB-Token": token,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (res.status === 403) {
    // The page holds a stale session token (older CCBridge install); reload once to get the current one.
    const last = Number(sessionStorage.getItem("ccb-reload") ?? 0);
    if (Date.now() - last > 10_000) {
      sessionStorage.setItem("ccb-reload", String(Date.now()));
      location.reload();
    }
    throw new Error("session expired; reload the page");
  }
  if (!res.ok) {
    const d = data as { error?: string; errId?: string; code?: string; hint?: string };
    // The id is also in the log: it leads to the details when investigating.
    throw new Error(`${d.error ?? `HTTP ${res.status}`}${d.hint ? ` ${d.hint}` : ""}${d.errId ? ` (error ${d.errId}${d.code ? `, ${d.code}` : ""})` : ""}`);
  }
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
    | "review"
    | "kind"
    | "next-steps";
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
  /** Scheduled messages, fetches and runbooks. */
  schedules?: ScheduleItem[];
  /** Set while the queue waits for Copilot's daily limit to reset (local time). */
  pausedUntil?: string | null;
  /** Release tag (v0.1.12) and the commit it was built from (short hash). */
  release?: string;
  commit?: string;
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
  kind: "chat" | "fetch" | "runbook";
  name: string;
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
}

export interface ScheduleSpec {
  kind: "chat" | "fetch" | "runbook";
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

/** A project runbook (runbooks/<name>.runbook.md) and its output file. */
export interface RunbookItem {
  name: string;
  title: string;
  path: string;
  output: string;
  lastRun: string | null;
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
  type: "number" | "select";
  value: string | number | null;
  default: string | number | null;
  custom: boolean;
  min?: number;
  max?: number;
  options?: string[];
}

/** A saved fetch prompt (fetch/<name>.prompt.md) and its latest answer (fetch/<name>.md). */
export interface FetchItem {
  name: string;
  prompt: string;
  promptPath: string;
  output: string;
  fetchedAt: string | null;
  outputSize: number;
}

export interface FileInfo {
  path: string;
  size: number;
  /** Lines added / removed since the project was opened (only for changed files). */
  added?: number;
  removed?: number;
}

// Whatever the server (and Copilot behind it) sends, the UI only ever renders strings here.
const TEXT_FIELDS = ["text", "target", "summary", "output", "error", "warning", "status", "action", "id", "decidedBy", "errId", "code", "hint", "detail", "version"] as const;

function asText(v: unknown): string | undefined {
  if (v === null || v === undefined) return undefined;
  return typeof v === "string" ? v : typeof v === "object" ? JSON.stringify(v) : String(v);
}

export function normalizeEvent(raw: AgentEvent): AgentEvent {
  const e = { ...raw } as AgentEvent & Record<string, unknown>;
  for (const k of TEXT_FIELDS) if (k in e) (e as Record<string, unknown>)[k] = asText(e[k]);
  if (e.references !== undefined) {
    e.references = (Array.isArray(e.references) ? e.references : [])
      .filter((r): r is Reference => !!r && typeof r === "object")
      .map((r) => ({ title: asText(r.title) ?? null, url: asText(r.url) ?? null, kind: asText(r.kind) ?? null }));
  }
  if (e.items !== undefined && !Array.isArray(e.items)) e.items = [];
  if (e.files !== undefined && !Array.isArray(e.files)) e.files = [];
  if (e.steps !== undefined) e.steps = (Array.isArray(e.steps) ? e.steps : []).map((s) => asText(s) ?? "").filter(Boolean);
  if (e.reasons !== undefined) e.reasons = (Array.isArray(e.reasons) ? e.reasons : [e.reasons]).map((s) => asText(s) ?? "").filter(Boolean);
  if (e.next !== undefined) e.next = asText(e.next);
  return e;
}

/** Reports a page error to the CCBridge log (best effort). */
export function reportClientError(message: string, detail: Record<string, unknown> = {}) {
  fetch("/api/clientlog", {
    method: "POST",
    headers: { "X-CCB-Token": token, "Content-Type": "application/json" },
    body: JSON.stringify({ message, ...detail }),
  }).catch(() => {});
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
  chat: (text: string, asCoding = false) => call<{ ok: boolean }>("POST", "/api/chat", { text, asCoding }),
  fetchList: () => call<{ items: FetchItem[] }>("GET", "/api/fetch").then((r) => (Array.isArray(r.items) ? r.items : [])),
  saveFetch: (name: string, prompt: string) => call<{ ok: boolean; item: FetchItem }>("POST", "/api/fetch", { name, prompt }),
  runFetch: (name: string) => call<{ ok: boolean }>("POST", "/api/fetch/run", { name }),
  runbooks: () =>
    call<{ runbooks: RunbookItem[]; templates: RunbookTemplate[] }>("GET", "/api/runbooks").then((r) => ({
      runbooks: asList(r.runbooks),
      templates: asList(r.templates),
    })),
  createRunbook: (template: string, name: string) => call<{ ok: boolean; item: RunbookItem }>("POST", "/api/runbooks", { template, name }),
  runRunbook: (name: string) => call<{ ok: boolean }>("POST", "/api/runbooks/run", { name }),
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
  updateSchedule: (id: string, change: { enabled?: boolean }) => call<{ ok: boolean }>("POST", "/api/schedules/update", { id, ...change }),
  deleteSchedule: (id: string) => call<{ ok: boolean }>("POST", "/api/schedules/delete", { id }),
  runSchedule: (id: string) => call<{ ok: boolean }>("POST", "/api/schedules/run", { id }),
  showProject: () => call<{ ok: boolean }>("POST", "/api/project/show"),
  settings: () => call<{ settings: Setting[] }>("GET", "/api/settings").then((r) => (Array.isArray(r.settings) ? r.settings : [])),
  setSetting: (key: string, value: string | number | null) =>
    call<{ ok: boolean; settings: Setting[] }>("POST", "/api/settings", { key, value }).then((r) => ({ ...r, settings: Array.isArray(r.settings) ? r.settings : [] })),
  setWorkIq: (value: "on" | "off" | "leave") => call<{ ok: boolean }>("POST", "/api/workiq", { value }),
  setLogging: (level: "off" | "info" | "verbose" | "trace") => call<{ ok: boolean }>("POST", "/api/logging", { level }),
  diagnostics: () => call<{ ok: boolean; path: string; fullPath: string }>("POST", "/api/diagnostics"),
  showDiagnostics: (path: string) => call<{ ok: boolean }>("POST", "/api/diagnostics/show", { path }),
  /** Uploads a file into the project's read-only source/ folder, reporting progress 0-100. */
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
          } catch {}
          reject(new Error(msg));
        }
      };
      xhr.onerror = () => reject(new Error("Upload failed"));
      xhr.send(file);
    }),
};
