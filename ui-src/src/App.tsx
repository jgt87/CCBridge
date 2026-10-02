import {
  AtSign,
  ClipboardList,
  FileCode2,
  FileArchive,
  FolderOpen,
  Menu as MenuIcon,
  ScrollText,
  MessageSquarePlus,
  PencilRuler,
  RotateCcw,
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
import { ProjectPicker } from "@/components/ccb/project-picker";
import { SidePanel } from "@/components/ccb/side-panel";
import { buildTranscript, Transcript } from "@/components/ccb/transcript";
import { type AgentEvent, type AppState, api, type FileInfo, type Mode } from "@/lib/api";

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
  const [draft, setDraft] = useState("");
  const [palette, setPalette] = useState<null | "commands" | "attach">(null);
  const [viewer, setViewer] = useState<{ path: string; text: string } | null>(null);
  const [showPicker, setShowPicker] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState<{ text: string; path?: string } | null>(null);
  const [focusKey, setFocusKey] = useState(0);
  const [newChatPending, setNewChatPending] = useState(false);
  const [stopping, setStopping] = useState(false);
  const lastSeq = useRef(0);

  const refreshFiles = useCallback(() => {
    api.files().then((r) => setFiles(r.files), () => {});
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
        if (r.events.length) {
          lastSeq.current = r.events[r.events.length - 1].seq;
          setEvents((prev) => [...prev, ...r.events]);
          if (r.events.some((e) => e.type === "project" || e.type === "undo" || (e.type === "action-result" && e.changed))) refreshFiles();
          if (r.events.some((e) => e.type === "newchat" || e.type === "error")) setNewChatPending(false);
        }
        setError("");
      } catch (e) {
        setError(`Lost contact with CCBridge: ${(e as Error).message}. Is the PowerShell window still open?`);
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
  const changes = useMemo(
    () => projectEvents.filter((e) => e.type === "checkpoint").map((e) => ({ seq: e.seq, time: e.time, files: e.files ?? [] })),
    [projectEvents]
  );

  const send = async (text: string) => {
    try {
      await api.chat(text);
      setDraft("");
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const openFile = async (path: string) => {
    try {
      setViewer(await api.file(path));
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const fileActions: Action[] = files.map((f) => ({
    id: `file:${f.path}`,
    label: f.path.split("/").pop() ?? f.path,
    description: f.path,
    icon: <FileCode2 className="h-4 w-4 text-muted-foreground" />,
    end: palette === "attach" ? "Attach" : "Open",
    onSelect: () => {
      if (palette === "attach") {
        setDraft((d) => `${d}${d && !d.endsWith(" ") ? " " : ""}@${f.path} `);
        setFocusKey((k) => k + 1);
      } else openFile(f.path);
    },
  }));

  const commandActions: Action[] = [
    { id: "new-chat", label: "New Copilot chat", description: "Start fresh; the project stays open", icon: <MessageSquarePlus className="h-4 w-4 text-muted-foreground" />, end: "Command", onSelect: startNewChat },
    { id: "undo", label: "Undo last change set", description: "Restore files from before the last message", icon: <RotateCcw className="h-4 w-4 text-muted-foreground" />, end: "Command", onSelect: () => api.undo() },
    { id: "project", label: "Switch project", description: "Open or create a OneDrive project", icon: <FolderOpen className="h-4 w-4 text-muted-foreground" />, end: "Command", onSelect: () => setShowPicker(true) },
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
        <div className="flex items-center gap-2 font-semibold tracking-tight">
          <span className="grid h-7 w-7 place-items-center rounded-lg bg-foreground text-background text-xs">CC</span>
          CCBridge
        </div>
        {state.project && (
          <button
            className="flex min-w-0 items-center gap-1.5 rounded-lg px-2 py-1 text-muted-foreground text-sm hover:bg-black/5 hover:text-foreground dark:hover:bg-white/5"
            onClick={() => setShowPicker(true)}
            title={state.project.path}
            type="button"
          >
            <FolderOpen className="h-4 w-4" />
            <span className="truncate">{state.project.name}</span>
          </button>
        )}
        <div className="flex-1" />
        <CommandButton className="h-8" icon={MenuIcon} onClick={() => setPalette("commands")} title="Commands and files (Ctrl+K)">
          Menu
        </CommandButton>
      </header>

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
          <aside className="hidden w-80 shrink-0 flex-col border-black/10 border-r p-3 lg:flex dark:border-white/10">
            <div className="min-h-0 flex-1">
              <SidePanel busy={state.busy} changes={changes} files={files} onOpenFile={openFile} onUndo={() => api.undo()} onUploaded={refreshFiles} todos={state.todos} />
            </div>
            {state.version && (
              <div className="shrink-0 px-1 pt-2 text-muted-foreground text-xs" title="Installed CCBridge version; updates install automatically at start (or run update.cmd)">
                CCBridge {state.version}
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
                            Describe the change. Copilot reads the project, proposes edits and commands, and CCBridge applies them after your approval.
                            Type <span className="font-mono">@</span> or use the @ button to attach files.
                          </p>
                        </div>
                      </>
                    )}
                  </div>
                }
                items={transcript}
                progress={state.progress}
              />
              </ErrorBoundary>
            </div>
            <div className="shrink-0 px-4">
              <div className="mx-auto max-w-3xl">
                <AI_Prompt
                  busy={state.busy}
                  disabled={!state.project}
                  focusKey={focusKey}
                  headerLeft={
                    <span className="truncate">
                      {state.project?.name} · {MODES.find((m) => m.id === state.mode)?.description}
                    </span>
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
                      {state.copilot === "error" && (
                        <span className="text-rose-500" title={state.copilotMessage}>
                          Copilot unavailable
                        </span>
                      )}
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
                        <span className="text-muted-foreground" title="Messages used in this Copilot chat; CCBridge starts a new chat with a summary before the limit">
                          {state.throttle.used}/{state.throttle.max}
                        </span>
                      )}
                      <button className="hover:underline disabled:opacity-50" disabled={newChatPending} onClick={startNewChat} type="button">
                        {newChatPending ? "Starting..." : "New chat"}
                      </button>
                    </span>
                  }
                  mode={state.mode}
                  modes={MODES}
                  onAttach={() => setPalette("attach")}
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
        <div className="fixed inset-0 z-50 flex items-start justify-center bg-black/40 px-4 pt-24 backdrop-blur-sm" onMouseDown={() => setPalette(null)}>
          <div className="w-full max-w-xl rounded-2xl bg-background px-4 pb-4 shadow-2xl" onMouseDown={(e) => e.stopPropagation()}>
            <ActionSearchBar
              actions={palette === "attach" ? fileActions : commandActions}
              key={palette}
              label={palette === "attach" ? "Attach a project file" : "Commands and files"}
              onClose={() => setPalette(null)}
              placeholder={palette === "attach" ? "File name..." : "Type a command or file name..."}
            />
          </div>
        </div>
      )}

      {/* File viewer */}
      {viewer && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-6 backdrop-blur-sm" onMouseDown={() => setViewer(null)}>
          <div className="flex max-h-full w-full max-w-4xl flex-col overflow-hidden rounded-2xl bg-background shadow-2xl" onMouseDown={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between border-black/10 border-b px-4 py-2 dark:border-white/10">
              <span className="font-mono text-sm">{viewer.path}</span>
              <button onClick={() => setViewer(null)} type="button">
                <X className="h-4 w-4" />
              </button>
            </div>
            <pre className="min-h-0 flex-1 overflow-auto p-4 font-mono text-xs leading-5">{viewer.text}</pre>
          </div>
        </div>
      )}
    </div>
  );
}
