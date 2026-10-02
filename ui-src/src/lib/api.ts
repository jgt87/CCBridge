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
  if (!res.ok) throw new Error((data as { error?: string }).error ?? `HTTP ${res.status}`);
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
    | "fetch";
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
  name?: string;
  path?: string;
}

export interface AppState {
  project: { name: string; path: string } | null;
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
const TEXT_FIELDS = ["text", "target", "summary", "output", "error", "warning", "status", "action", "id", "decidedBy"] as const;

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
  chat: (text: string) => call<{ ok: boolean }>("POST", "/api/chat", { text }),
  fetchList: () => call<{ items: FetchItem[] }>("GET", "/api/fetch").then((r) => (Array.isArray(r.items) ? r.items : [])),
  saveFetch: (name: string, prompt: string) => call<{ ok: boolean; item: FetchItem }>("POST", "/api/fetch", { name, prompt }),
  runFetch: (name: string) => call<{ ok: boolean }>("POST", "/api/fetch/run", { name }),
  approve: (id: string, decision: "approve" | "reject", note = "") =>
    call<{ ok: boolean }>("POST", "/api/approve", { id, decision, note, by: "user" }),
  setMode: (mode: Mode) => call<{ ok: boolean }>("POST", "/api/mode", { mode }),
  newChat: () => call<{ ok: boolean }>("POST", "/api/newchat"),
  undo: () => call<{ ok: boolean }>("POST", "/api/undo"),
  stop: () => call<{ ok: boolean }>("POST", "/api/stop"),
  connect: () => call<{ ok: boolean }>("POST", "/api/connect"),
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
