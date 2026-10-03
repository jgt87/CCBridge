import {
  AtSign,
  ClipboardList,
  FileCode2,
  FileArchive,
  FolderOpen,
  Menu as MenuIcon,
  ScrollText,
  MessageSquarePlus,
  PanelLeftOpen,
  PencilRuler,
  RotateCcw,
  Settings,
  ShieldCheck,
  X,
  Zap,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import ActionSearchBar, { type Action } from "@/components/kokonutui/action-search-bar";
import AI_Prompt, { type PromptMode } from "@/components/kokonutui/ai-prompt";
import CommandButton from "@/components/kokonutui/command-button";
import Loader from "@/components/kokonutui/loader";
import { ErrorBoundary } from "@/components/ccb/error-boundary";
import { CopilotStatus } from "@/components/ccb/copilot-status";
import { SettingsPanel } from "@/components/ccb/settings-panel";
import { ProjectPicker } from "@/components/ccb/project-picker";
import { SidePanel } from "@/components/ccb/side-panel";
import type { ScheduleTarget } from "@/components/ccb/schedule-form";
import { SchedulesModal } from "@/components/ccb/schedules-modal";
import { FileViewer } from "@/components/ccb/file-viewer";
import { SplitViewHint } from "@/components/ccb/split-view-hint";
import { ModalBackdrop } from "@/components/ccb/modal-backdrop";
import { notifyEvents, notifyQueue } from "@/lib/notify";
import type { ChatOptions } from "@/lib/api";
import { buildTranscript, Transcript } from "@/components/ccb/transcript";
import { type AgentEvent, type AppState, api, type FetchItem, type FileInfo, type Mode, type RunbookItem, type RunbookTemplate } from "@/lib/api";
import { fetchedAge } from "@/components/ccb/fetch-panel";

const MODES: PromptMode[] = [
  { id: "ask", label: "Ask before changes", description: "Approve every file change and command", icon: <ShieldCheck className="h-3.5 w-3.5 text-muted-foreground" /> },
  { id: "auto", label: "Auto-accept edits", description: "Apply file changes directly; still ask for commands", icon: <Zap className="h-3.5 w-3.5 text-muted-foreground" /> },
  { id: "plan", label: "Plan only", description: "Read and discuss; no changes, no commands", icon: <PencilRuler className="h-3.5 w-3.5 text-muted-foreground" /> },
];

const EMPTY_STATE: AppState = {
  project: null, mode: "ask", busy: false, progress: "", copilot: "idle", copilotMessage: "",
  throttle: { used: 0, max: 0 }, credits: null, todos: [], promptLimit: 0,
  workIq: "leave", workIqActual: null, workIqAvailable: false, logLevel: "info", version: "",
};

export default function App() {
  const [state, setState] = useState<AppState>(EMPTY_STATE);
  const [events, setEvents] = useState<AgentEvent[]>([]);
  const [files, setFiles] = useState<FileInfo[]>([]);
  const [fetchItems, setFetchItems] = useState<FetchItem[]>([]);
  const [runbooks, setRunbooks] = useState<RunbookItem[]>([]);
  const [runbookTemplates, setRunbookTemplates] = useState<RunbookTemplate[]>([]);
  const [draft, setDraft] = useState("");
  // Schedules modal: closed (null), the list ({ target: null }) or a form for a target.
  const [scheduling, setScheduling] = useState<{ target: ScheduleTarget | null } | null>(null);
  const [reviewTick, setReviewTick] = useState(0);
  // Clarify first: remembered in this browser.
  const [clarifyFirst, setClarifyFirst] = useState(() => {
    try {
      return localStorage.getItem("ccb.clarify") === "1";
    } catch {
      return false;
    }
  });
  const toggleClarify = () =>
    setClarifyFirst((on) => {
      try {
        localStorage.setItem("ccb.clarify", on ? "0" : "1");
      } catch {
        /* storage blocked: only this session */
      }
      return !on;
    });
  const queueSeen = useRef(new Map<string, string>());
  const pauseSeen = useRef<string | null | undefined>(undefined);
  const [palette, setPalette] = useState<null | "commands" | "attach">(null);
  const [viewer, setViewer] = useState<{ path: string; text: string } | null>(null);
  const [queuedNote, setQueuedNote] = useState(false);
  const [showPicker, setShowPicker] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState<{ text: string; path?: string } | null>(null);
  const [focusKey, setFocusKey] = useState(0);
  const [newChatPending, setNewChatPending] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  const lastSeq = useRef(0);

  // Side panel: always beside the chat when the window is wide enough. On a narrow window it is
  // hidden and a button (shown only then) opens it over the chat; a click beside it or Esc closes it.
  const [wide, setWide] = useState(() => window.matchMedia("(min-width: 1024px)").matches);
  const [drawerOpen, setDrawerOpen] = useState(false);
  useEffect(() => {
    if (!drawerOpen) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setDrawerOpen(false);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [drawerOpen]);
  useEffect(() => {
    const mq = window.matchMedia("(min-width: 1024px)");
    const onChange = () => {
      setWide(mq.matches);
      setDrawerOpen(false);
    };
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);
  const sideVisible = wide || drawerOpen;

  const refreshFiles = useCallback(() => {
    api.files().then((r) => setFiles(r.files), () => {});
    api.fetchList().then(setFetchItems, () => {});
    api.runbooks().then((r) => {
      setRunbooks(r.runbooks);
      setRunbookTemplates(r.templates);
    }, () => {});
  }, []);

  // Poll the server: new events plus a state snapshot.
  useEffect(() => {
    let stop = false;
    let timer = 0;
    const tick = async () => {
      try {
        const r = await api.poll(lastSeq.current);
        setState(r.state);
        if (!r.state.busy) setStopping(false);
        // Desktop notifications for queue changes (the first poll only records the current state).
        const q = r.state.queue ?? [];
        if (pauseSeen.current === undefined) {
          queueSeen.current = new Map(q.map((x) => [x.id, x.status]));
          pauseSeen.current = r.state.pausedUntil ?? null;
        } else {
          queueSeen.current = notifyQueue(queueSeen.current, q, pauseSeen.current, r.state.pausedUntil);
          pauseSeen.current = r.state.pausedUntil ?? null;
        }
        if (r.events.length) {
          lastSeq.current = r.events[r.events.length - 1].seq;
          setEvents((prev) => [...prev, ...r.events]);
          notifyEvents(r.events);
          if (r.events.some((e) => e.type === "project" || e.type === "undo" || e.type === "fetch" || e.type === "runbook" || e.type === "review" || (e.type === "action-result" && e.changed))) refreshFiles();
          if (r.events.some((e) => e.type === "review" || e.type === "project" || (e.type === "action-result" && e.changed))) setReviewTick((t) => t + 1);
          if (r.events.some((e) => e.type === "newchat" || e.type === "error")) setNewChatPending(false);
        }
        setError("");
      } catch (e) {
        setError(`Lost contact with StreamHub: ${(e as Error).message}. Is the PowerShell window still open?`);
      }
      if (!stop) timer = window.setTimeout(tick, 400);
    };
    tick();
    return () => {
      stop = true;
      clearTimeout(timer);
    };
  }, [refreshFiles]);

  useEffect(() => {
    if (state.project) refreshFiles();
  }, [state.project?.path, refreshFiles]);

  // Ctrl/Cmd+K opens the command palette.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPalette((p) => (p ? null : "commands"));
      }
      if (e.key === "Escape") setDrawerOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const projectEvents = useMemo(() => {
    // Only show the transcript since the last project switch.
    let idx = -1;
    events.forEach((e, i) => {
      if (e.type === "project") idx = i;
    });
    return idx >= 0 ? events.slice(idx) : events;
  }, [events]);

  // The chat view starts at the last explicit "New chat"; the Changes tab keeps the whole project session.
  const chatEvents = useMemo(() => {
    let idx = -1;
    projectEvents.forEach((e, i) => {
      if (e.type === "newchat") idx = i;
    });
    return idx >= 0 ? projectEvents.slice(idx) : projectEvents;
  }, [projectEvents]);
  const transcript = useMemo(() => buildTranscript(chatEvents), [chatEvents]);
  // The user's own messages in this project, oldest first, consecutive repeats once (Arrow Up history).
  const promptHistory = useMemo(() => {
    const out: string[] = [];
    for (const e of projectEvents) {
      const t = e.type === "user" ? (e.text ?? "").trim() : "";
      if (t && out[out.length - 1] !== t) out.push(t);
    }
    return out;
  }, [projectEvents]);

  const startNewChat = () => {
    setNewChatPending(true);
    if (state.busy) setStopping(true);
    api.newChat().catch((e) => {
      setNewChatPending(false);
      setError((e as Error).message);
    });
    window.setTimeout(() => setNewChatPending(false), 30000);
  };

  const stop = () => {
    setStopping(true);
    api.stop().catch(() => setStopping(false));
  };
  // The side panel shows the open project only: its queue and schedules (items without a project,
  // such as a new chat, belong to every project).
  const projectKey = (state.project?.path ?? "").replace(/\\+$/, "").toLowerCase();
  const queueHere = useMemo(
    () => (state.queue ?? []).filter((q) => !q.projectRoot || q.projectRoot.replace(/\\+$/, "").toLowerCase() === projectKey),
    [state.queue, projectKey]
  );
  const schedulesHere = useMemo(
    () => (state.schedules ?? []).filter((s) => !s.projectRoot || s.projectRoot.replace(/\\+$/, "").toLowerCase() === projectKey),
    [state.schedules, projectKey]
  );

  const changes = useMemo(
    () => projectEvents.filter((e) => e.type === "checkpoint").map((e) => ({ seq: e.seq, time: e.time, files: e.files ?? [] })),
    [projectEvents]
  );

  const send = async (text: string) => {
    try {
      await api.chat(text, { clarify: clarifyFirst });
      setDraft("");
      // Sent while busy = queued: say when it runs (only while StreamHub stays open).
      if (state.busy) {
        setQueuedNote(true);
        window.setTimeout(() => setQueuedNote(false), 8000);
      }
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const openFile = async (path: string) => {
    setDrawerOpen(false);
    try {
      setViewer(await api.file(path));
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const attachPath = (path: string) => {
    setDraft((d) => `${d}${d && !d.endsWith(" ") ? " " : ""}@${path} `);
    setFocusKey((k) => k + 1);
  };

  const fetchedByPath = new Map(fetchItems.map((it) => [it.output, it]));
  const fileActions: Action[] = files.map((f) => ({
    id: `file:${f.path}`,
    label: f.path.split("/").pop() ?? f.path,
    // Fetched data shows how old it is, so stale data is easy to spot before attaching.
    description: fetchedByPath.has(f.path) ? `${f.path} - fetched ${fetchedAge(fetchedByPath.get(f.path)!.fetchedAt)}` : f.path,
    icon: <FileCode2 className="h-4 w-4 text-muted-foreground" />,
    end: palette === "attach" ? "Attach" : "Open",
    onSelect: () => {
      if (palette === "attach") attachPath(f.path);
      else openFile(f.path);
    },
  }));

  const commandActions: Action[] = [
    { id: "new-chat", label: "New Copilot chat", description: "Start fresh; the project stays open", icon: <MessageSquarePlus className="h-4 w-4 text-muted-foreground" />, end: "Command", onSelect: startNewChat },
    { id: "undo", label: "Undo last change set", description: "Restore files from before the last message", icon: <RotateCcw className="h-4 w-4 text-muted-foreground" />, end: "Command", onSelect: () => api.undo() },
    { id: "settings", label: "Settings", description: "Pacing, retries, checks, timeouts and sizes for this computer", icon: <Settings className="h-4 w-4 text-muted-foreground" />, end: "Command", onSelect: () => setTimeout(() => setShowSettings(true), 0) },
    { id: "project", label: "Switch worktree", description: "Open or create a OneDrive project folder", icon: <FolderOpen className="h-4 w-4 text-muted-foreground" />, end: "Command", onSelect: () => setShowPicker(true) },
    { id: "attach", label: "Attach a file to the message", description: "Adds @path so Copilot gets the file", icon: <AtSign className="h-4 w-4 text-muted-foreground" />, end: "Command", onSelect: () => setTimeout(() => setPalette("attach"), 0) },
    {
      id: "logging",
      label: state.logLevel === "verbose" || state.logLevel === "trace" ? "Verbose logging: turn off" : "Verbose logging: turn on",
      description: `Detailed diagnostic log (now: ${state.logLevel}); stays on after restarts`,
      icon: <ScrollText className="h-4 w-4 text-muted-foreground" />,
      end: "Diagnostics",
      onSelect: () => api.setLogging(state.logLevel === "verbose" || state.logLevel === "trace" ? "info" : "verbose").then(() => setNotice({ text: `Logging set to ${state.logLevel === "verbose" || state.logLevel === "trace" ? "info" : "verbose"}.` })),
    },
    {
      id: "diagnostics",
      label: "Export diagnostics",
      description: "Zip logs and an environment summary to your desktop",
      icon: <FileArchive className="h-4 w-4 text-muted-foreground" />,
      end: "Diagnostics",
      onSelect: () => {
        setNotice({ text: "Collecting diagnostics..." });
        api.diagnostics().then(
          (r) => setNotice({ text: `Diagnostics saved: ${r.path}`, path: r.fullPath }),
          (e) => setError((e as Error).message)
        );
      },
    },
    ...MODES.map((m) => ({ id: `mode:${m.id}`, label: `Mode: ${m.label}`, description: m.description, icon: m.icon, end: state.mode === m.id ? "Active" : "Mode", onSelect: () => api.setMode(m.id as Mode) })),
    ...fileActions,
  ];

  const pickerOpen = !state.project || showPicker;

  return (
    <div className="flex h-screen flex-col bg-background text-foreground">
      {/* Header */}
      <header className="flex h-14 shrink-0 items-center gap-3 border-black/10 border-b px-4 dark:border-white/10">
        {state.project && !pickerOpen && !sideVisible && (
          <button
            aria-label="Open side panel"
            className="-ml-1.5 grid h-8 w-8 place-items-center rounded-lg text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5"
            onClick={() => setDrawerOpen(true)}
            title="Open side panel (the window is too narrow to show it beside the chat)"
            type="button"
          >
            <PanelLeftOpen className="h-4 w-4" />
          </button>
        )}
        <div className="flex items-center gap-2 font-semibold tracking-tight">
          <span className="grid h-7 w-7 place-items-center rounded-lg bg-foreground text-background text-xs">SH</span>
          <span>StreamHub <span className="ml-0.5 font-normal text-muted-foreground">by JGT</span></span>
        </div>
        {state.project && (
          <button
            className="flex min-w-0 items-center gap-1.5 rounded-lg px-2 py-1 text-muted-foreground text-sm hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5"
            onClick={() => setShowPicker(true)}
            title={`${state.project.name}\n${state.project.path}\nClick to open or create another project`}
            type="button"
          >
            <FolderOpen className="h-4 w-4" />
            <span className="truncate">Switch worktree</span>
          </button>
        )}
        <div className="flex-1" />
        <CopilotStatus copilot={state.copilot} message={state.copilotMessage} />
        <button
          aria-label="Settings"
          className="grid h-8 w-8 place-items-center rounded-lg text-muted-foreground hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5"
          onClick={() => setShowSettings(true)}
          title="Settings"
          type="button"
        >
          <Settings className="h-4 w-4" />
        </button>
        <CommandButton className="h-8" icon={MenuIcon} onClick={() => setPalette("commands")} title="Commands and files (Ctrl+K)">
          Menu
        </CommandButton>
      </header>

      {showSettings && <SettingsPanel onClose={() => setShowSettings(false)} />}

      {notice && (
        <div className="flex items-center justify-between gap-3 bg-black/5 px-4 py-2 text-sm dark:bg-white/10">
          <span className="truncate">{notice.text}</span>
          <span className="flex shrink-0 items-center gap-3">
            {notice.path && (
              <button className="hover:underline" onClick={() => api.showDiagnostics(notice.path!)} type="button">
                Show in folder
              </button>
            )}
            <button onClick={() => setNotice(null)} type="button">
              <X className="h-4 w-4" />
            </button>
          </span>
        </div>
      )}

      {error && (
        <div className="flex items-center justify-between bg-rose-500/10 px-4 py-2 text-rose-600 text-sm dark:text-rose-400">
          {error}
          <button onClick={() => setError("")} type="button">
            <X className="h-4 w-4" />
          </button>
        </div>
      )}

      {pickerOpen ? (
        <main className="flex-1 overflow-y-auto">
          {state.project && (
            <div className="mx-auto max-w-xl px-4 pt-6">
              <button className="text-muted-foreground text-sm hover:text-foreground" onClick={() => setShowPicker(false)} type="button">
                ← Back to {state.project.name}
              </button>
            </div>
          )}
          <ProjectPicker onOpened={() => setShowPicker(false)} />
        </main>
      ) : (
        <div className="flex min-h-0 flex-1">
          {/* Side panel (left) */}
          {/* The chat is not dimmed: a click beside the open panel only closes it. */}
          {!wide && drawerOpen && <div aria-hidden className="fixed inset-0 top-14 z-30" onClick={() => setDrawerOpen(false)} />}
          <aside
            className={
              wide
                ? `flex w-80 shrink-0 flex-col border-black/10 border-r p-3 dark:border-white/10`
                : `${drawerOpen ? "flex" : "hidden"} fixed top-14 bottom-0 left-0 z-40 w-80 max-w-[85vw] flex-col border-black/10 border-r bg-background p-3 shadow-lg dark:border-white/10`
            }
          >
            <div className="min-h-0 flex-1">
              <SidePanel
                key={state.project?.path ?? "none"}
                busy={state.busy}
                changes={changes}
                fetchItems={fetchItems}
                files={files}
                onAttach={attachPath}
                onOpenFile={openFile}
                onRunFetch={(name) => api.runFetch(name).catch((e) => setError((e as Error).message))}
                onSaveFetch={async (name, prompt) => {
                  await api.saveFetch(name, prompt);
                  refreshFiles();
                }}
                onUndo={() => api.undo()}
                onUploaded={refreshFiles}
                onCreateRunbook={async (template, name) => {
                  await api.createRunbook(template, name);
                  refreshFiles();
                }}
                onRunRunbook={(name) => api.runRunbook(name).catch((e) => setError((e as Error).message))}
                project={state.project}
                queue={queueHere}
                schedules={schedulesHere}
                reviewTick={reviewTick}
                issueStamp={state.issueStamp ?? ""}
                activity={state.activity ?? null}
                pausedUntil={state.pausedUntil}
                onSchedule={(target) => {
                  setScheduling({ target });
                  setDrawerOpen(false);
                }}
                runbookTemplates={runbookTemplates}
                runbooks={runbooks}
                todos={state.todos}
              />
            </div>
            {state.version && (
              <div
                className="flex shrink-0 items-center justify-center gap-2 px-1 pt-2 text-muted-foreground text-xs"
                title="Installed StreamHub release and the commit it was built from; updates install automatically at start (or run update.cmd)"
              >
                <span>StreamHub {state.release || state.version}</span>
                {state.commit && (
                  <>
                    <span aria-hidden className="h-3 w-px bg-black/15 dark:bg-white/20" />
                    <span className="font-mono">{state.commit}</span>
                  </>
                )}
              </div>
            )}
          </aside>

          {/* Chat column */}
          <main className="flex min-w-0 flex-1 flex-col">
            <div className="min-h-0 flex-1 overflow-y-auto">
              <ErrorBoundary
                area="chat view"
                context={() => ({ lastEvents: chatEvents.slice(-8).map((e) => ({ type: e.type, keys: Object.keys(e), refs: Array.isArray(e.references) ? e.references.length : undefined })) })}
                key={chatEvents.length ? chatEvents[0].seq : 0}
              >
              <Transcript
                activity={state.activity ?? null}
                busy={state.busy}
                stopping={stopping}
                empty={
                  <div className="flex h-full flex-col items-center justify-center gap-6 px-6 py-16 text-center">
                    {state.copilot === "connecting" ? (
                      <Loader size="sm" subtitle={state.copilotMessage || "Opening Copilot in Edge"} title="Connecting to Copilot" />
                    ) : (
                      <>
                        <ClipboardList className="h-10 w-10 text-muted-foreground/50" />
                        <div className="max-w-md space-y-1">
                          <p className="font-medium">What should we build in {state.project?.name}?</p>
                          <p className="text-muted-foreground text-sm">
                            Describe the change. Copilot reads the project, proposes edits and commands, and StreamHub applies them after your approval.
                            Type <span className="font-mono">@</span> or use the @ button to attach files.
                          </p>
                        </div>
                      </>
                    )}
                  </div>
                }
                items={transcript}
                onResendAsCoding={(text) => api.chat(text, { asCoding: true }).catch((e) => setError((e as Error).message))}
                onSend={(text: string, opts: ChatOptions) => api.chat(text, opts).catch((e) => setError((e as Error).message))}
                onOpenFile={openFile}
                onUsePrompt={(text) => {
                  setDraft(text);
                  setFocusKey((k) => k + 1);
                }}
                progress={state.progress}
              />
              </ErrorBoundary>
            </div>
            <div className="shrink-0 px-4">
              <div className="mx-auto max-w-[max(48rem,80%)]">
                {scheduling && (
                  <SchedulesModal
                    fetchItems={fetchItems}
                    files={files}
                    initial={scheduling.target}
                    onClose={() => setScheduling(null)}
                    onCreate={async (spec) => {
                      await api.createSchedule(spec);
                      if (spec.kind === "chat" && spec.text === draft) setDraft("");
                    }}
                    runbooks={runbooks}
                    schedules={schedulesHere}
                  />
                )}
                <AI_Prompt
                  busy={state.busy}
                  disabled={!state.project}
                  focusKey={focusKey}
                  history={promptHistory}
                  headerLeft={
                    queuedNote ? (
                      <span className="truncate font-medium" title="Waiting tasks run while StreamHub is open; if you close it, they continue at the next start.">
                        Queued: runs after the current task, while StreamHub stays open.
                      </span>
                    ) : (
                      <span className="truncate">
                        {state.project?.name} · {MODES.find((m) => m.id === state.mode)?.description}
                      </span>
                    )
                  }
                  headerRight={
                    <span className="flex items-center gap-2">
                      {state.workIqAvailable && (
                        <button
                          className="rounded-md bg-black/5 px-2 py-0.5 hover:bg-black/10 dark:bg-white/10 dark:hover:bg-white/15"
                          onClick={() => api.setWorkIq(state.workIq === "on" ? "off" : "on")}
                          title="Work IQ lets Copilot use your Microsoft 365 data: Outlook, Teams, calendar, OneDrive and SharePoint"
                          type="button"
                        >
                          Work IQ {state.workIq === "on" ? "on" : state.workIq === "off" ? "off" : "(page setting)"}
                        </button>
                      )}
                      <select
                        className="rounded-md bg-black/5 px-1.5 py-0.5 text-xs outline-none hover:bg-black/10 dark:bg-white/10 dark:hover:bg-white/15"
                        onChange={(e) => api.setResponseMode(e.target.value).catch((err) => setError((err as Error).message))}
                        title={`Copilot's response mode (Auto / Quick response / Think deeper)${state.responseModeActual ? `; the page shows: ${state.responseModeActual}` : ""}`}
                        value={state.responseMode ?? "leave"}
                      >
                        <option value="leave">Response: page setting</option>
                        <option value="auto">Response: Auto</option>
                        <option value="quick">Response: Quick</option>
                        <option value="deep">Response: Think deeper</option>
                      </select>
                      {state.credits && state.credits.remaining <= 10 && (
                        <span
                          className={state.credits.remaining === 0 ? "text-rose-500" : "text-muted-foreground"}
                          title={`Copilot daily credits; they reset at ${new Date(state.credits.resetAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`}
                        >
                          {state.credits.remaining === 0
                            ? `Out of Copilot credits until ${new Date(state.credits.resetAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`
                            : `${state.credits.remaining} credits left`}
                        </span>
                      )}
                      {state.throttle.max > 0 && (
                        <span className="text-muted-foreground" title="Messages used in this Copilot chat; StreamHub starts a new chat with a summary before the limit">
                          {state.throttle.used}/{state.throttle.max}
                        </span>
                      )}
                      <button
                        className="inline-flex items-center gap-1 rounded-md border border-black/10 bg-black/5 px-2 py-0.5 text-foreground hover:bg-black/10 disabled:opacity-50 dark:border-white/10 dark:bg-white/10 dark:hover:bg-white/15"
                        disabled={newChatPending}
                        onClick={startNewChat}
                        title="Start a new Copilot conversation (the project stays open)"
                        type="button"
                      >
                        <MessageSquarePlus className="h-3.5 w-3.5" />
                        {newChatPending ? "Starting..." : "New chat"}
                      </button>
                    </span>
                  }
                  mode={state.mode}
                  modes={MODES}
                  onAttach={() => setPalette("attach")}
                  onSchedule={(text) => setScheduling({ target: { kind: "chat", text } })}
                  clarify={clarifyFirst}
                  onToggleClarify={toggleClarify}
                  onModeChange={(m) => api.setMode(m as Mode)}
                  onStop={stop}
                  onSubmit={send}
                  onValueChange={setDraft}
                  placeholder="Ask Copilot to build or change something..."
                  value={draft}
                />
              </div>
            </div>
          </main>
        </div>
      )}

      {/* Command palette */}
      {palette && (
        <ModalBackdrop className="pt-24" onClose={() => setPalette(null)}>
          <div className="w-full max-w-xl rounded-2xl bg-background px-4 pb-4 shadow-2xl">
            <ActionSearchBar
              actions={palette === "attach" ? fileActions : commandActions}
              key={palette}
              label={palette === "attach" ? "Attach a project file" : "Commands and files"}
              onClose={() => setPalette(null)}
              placeholder={palette === "attach" ? "File name..." : "Type a command or file name..."}
            />
          </div>
        </ModalBackdrop>
      )}

      {/* File viewer */}
      {/* Once, on first use in Edge: how to put StreamHub and Copilot side by side. */}
      {state.copilot === "ready" && <SplitViewHint appWindow={state.appWindow} shownBefore={Boolean(state.hints?.splitView)} />}
      {viewer && <FileViewer file={viewer} onClose={() => setViewer(null)} onOpenFile={openFile} previewBase={state.previewBase} />}
    </div>
  );
}
