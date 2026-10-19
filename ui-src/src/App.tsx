import { useCallback, useEffect, useMemo, useState } from "react";
import AI_Prompt from "@/components/kokonutui/ai-prompt";
import { ErrorBoundary } from "@/components/ccb/error-boundary";
import { SettingsPanel } from "@/components/ccb/settings-panel";
import { ProjectPicker } from "@/components/ccb/project-picker";
import { SidePanel } from "@/components/ccb/side-panel";
import type { ScheduleTarget } from "@/components/ccb/schedule-form";
import { SchedulesModal } from "@/components/ccb/schedules-modal";
import { FileViewer, type ViewerChange } from "@/components/ccb/file-viewer";
import { SplitViewHint } from "@/components/ccb/split-view-hint";
import { type AgentChoice, AppHeader, ChatEmpty, ErrorBar, InstallProblem, NoticeBar, PromptHeaderLeft, PromptHeaderRight, VersionLine } from "@/components/ccb/app-chrome";
import { MODES, type Notice, useCommandPalette } from "@/components/ccb/command-palette";
import { buildTranscript, Transcript } from "@/components/ccb/transcript";
import { useProjectLists } from "@/hooks/use-project-lists";
import { useServerPoll } from "@/hooks/use-server-poll";
import { useSideDrawer } from "@/hooks/use-side-drawer";
import { useStoredChoice } from "@/hooks/use-stored-choice";
import { useWorkTitle } from "@/hooks/use-work-title";
import { changeFileNote } from "@/lib/change-note";
import { changeSets, chatView, endsNewChat, inProject, keptView, projectKey, projectView, promptHistory as promptHistoryOf, touchesFiles, touchesReview } from "@/lib/event-views";
import { prefetchSettings } from "@/lib/settings-cache";
import { setLinksThroughEdge } from "@/lib/links";
import type { ChatOptions, ScheduleItem } from "@/lib/api";
import { type AgentEvent, type AppState, api, type Mode } from "@/lib/api";

const EMPTY_STATE: AppState = {
  project: null, mode: "ask", busy: false, progress: "", copilot: "idle", copilotMessage: "",
  throttle: { used: 0, max: 0 }, credits: null, todos: [], promptLimit: 0,
  workIq: "leave", workIqActual: null, workIqAvailable: false, logLevel: "info", version: "",
};

// Remembered in this browser: Clarify first, and who answers the next message (Auto, the default,
// lets StreamHub pick by fixed words: Researcher, Analyst or Copilot itself).
const parseClarify = (raw: string | null) => raw === "1";
const showClarify = (on: boolean) => (on ? "1" : "0");
const parseAgent = (raw: string | null): AgentChoice => (raw === "researcher" || raw === "analyst" || raw === "copilot" ? raw : "auto");
const showAgent = (v: AgentChoice) => v;

/** What goes with a message: the agent, and Clarify first (an agent itself is never clarified first). */
function sendOptions(agent: AgentChoice, clarify: boolean): ChatOptions {
  if (agent === "copilot") return { clarify };
  if (agent === "auto") return { agent, clarify };
  return { agent };
}

const IMAGE = /\.(png|jpe?g|gif|webp|svg|bmp)$/i;

export default function App() {
  const [state, setState] = useState<AppState>(EMPTY_STATE);
  const [events, setEvents] = useState<AgentEvent[]>([]);
  const [draft, setDraft] = useState("");
  // Schedules modal: closed (null), the list ({ target: null }) or a form for a target.
  const [scheduling, setScheduling] = useState<{ target: ScheduleTarget | null; editing?: ScheduleItem } | null>(null);
  const [reviewTick, setReviewTick] = useState(0);
  const [clarifyFirst, setClarifyFirst] = useStoredChoice("ccb.clarify", parseClarify, showClarify);
  const [agent, setAgent] = useStoredChoice("ccb.agent", parseAgent, showAgent);
  const [viewer, setViewer] = useState<{ path: string; text: string; change?: ViewerChange; note?: string } | null>(null);
  const [queuedNote, setQueuedNote] = useState(false);
  const [showPicker, setShowPicker] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState<Notice | null>(null);
  const [focusKey, setFocusKey] = useState(0);
  const [newChatPending, setNewChatPending] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  const { wide, drawerOpen, setDrawerOpen, sideVisible } = useSideDrawer();
  const lists = useProjectLists(state.project?.path, state.busy);
  const { files, fetchItems, runbooks, chains, scripts, refreshFiles } = lists;
  const fail = useCallback((e: unknown) => setError((e as Error).message), []);

  // External links open through StreamHub's Edge when the app is a tab there (lib/links.ts).
  useEffect(() => setLinksThroughEdge(Boolean(state.appInEdge)), [state.appInEdge]);

  // Settings opens complete: what it shows is loaded once in the background, a little after start.
  useEffect(() => {
    const t = window.setTimeout(() => void prefetchSettings(), 4000);
    return () => window.clearTimeout(t);
  }, []);

  useServerPoll({
    onState: (s) => {
      setState(s);
      if (!s.busy) setStopping(false);
    },
    onRestart: () => setEvents([]),
    onEvents: (evs) => {
      setEvents((prev) => [...prev, ...evs]);
      if (touchesFiles(evs)) refreshFiles();
      if (touchesReview(evs)) setReviewTick((t) => t + 1);
      if (endsNewChat(evs)) setNewChatPending(false);
    },
    onError: setError,
  });
  useWorkTitle(state.busy, state.work);

  const projectEvents = useMemo(() => projectView(events), [events]);
  // After "Clear chat history" (Settings > Privacy) nothing earlier is shown or recalled; the Changes
  // tab keeps its change sets (their backups still exist).
  const keptEvents = useMemo(() => keptView(projectEvents), [projectEvents]);
  const chatEvents = useMemo(() => chatView(keptEvents), [keptEvents]);
  const transcript = useMemo(() => buildTranscript(chatEvents), [chatEvents]);
  const promptHistory = useMemo(() => promptHistoryOf(keptEvents), [keptEvents]);
  const changes = useMemo(() => changeSets(projectEvents), [projectEvents]);
  // The side panel shows the open project only: its queue and schedules.
  const key = projectKey(state.project?.path);
  const queueHere = useMemo(() => inProject(state.queue, key), [state.queue, key]);
  const schedulesHere = useMemo(() => inProject(state.schedules, key), [state.schedules, key]);

  const startNewChat = () => {
    setNewChatPending(true);
    if (state.busy) setStopping(true);
    api.newChat().catch((e) => {
      setNewChatPending(false);
      fail(e);
    });
    window.setTimeout(() => setNewChatPending(false), 30000);
  };

  const stop = () => {
    setStopping(true);
    api.stop().catch(() => setStopping(false));
  };

  const send = async (text: string) => {
    try {
      await api.chat(text, sendOptions(agent, clarifyFirst));
      setDraft("");
      // Sent while busy = queued: say when it runs (only while StreamHub stays open).
      if (state.busy) {
        setQueuedNote(true);
        window.setTimeout(() => setQueuedNote(false), 8000);
      }
    } catch (e) {
      fail(e);
    }
  };

  const openFile = async (path: string) => {
    setDrawerOpen(false);
    try {
      // Images are shown from the project's read-only preview address, not read as text.
      if (IMAGE.test(path)) setViewer({ path, text: "" });
      else setViewer(await api.file(path));
    } catch (e) {
      fail(e);
    }
  };

  // From History: the file with the lines that change set added and removed (and the whole file a tab away).
  const openChangeFile = async (changeSet: string, path: string) => {
    setDrawerOpen(false);
    try {
      const d = await api.changeFile(changeSet, path);
      if (d.binary) return openFile(path); // no line view for binary files
      setViewer({ path, text: d.new, change: { note: changeFileNote(d), preview: { path, exists: d.exists, old: d.old ?? "", new: d.new } } });
    } catch (e) {
      fail(e);
    }
  };

  const attachPath = (path: string) => {
    setDraft((d) => `${d}${d && !d.endsWith(" ") ? " " : ""}@${path} `);
    setFocusKey((k) => k + 1);
  };

  const palette = useCommandPalette({
    state,
    files,
    fetchItems,
    attachPath,
    openFile,
    startNewChat,
    openSettings: () => setShowSettings(true),
    openPicker: () => setShowPicker(true),
    setLogLevel: (level) => setState((s) => ({ ...s, logLevel: level })),
    notice: setNotice,
    fail: setError,
  });

  // Side panel callbacks: report a failure in the error bar; those that write files refresh the tree.
  const orFail = <A extends unknown[]>(f: (...a: A) => Promise<unknown>) => (...a: A) => f(...a).catch(fail);
  const thenRefresh = <A extends unknown[]>(f: (...a: A) => Promise<unknown>) => async (...a: A) => {
    await f(...a);
    refreshFiles();
  };
  const scheduleFor = (s: { target: ScheduleTarget | null; editing?: ScheduleItem }) => {
    setScheduling(s);
    setDrawerOpen(false);
  };

  const pickerOpen = !state.project || showPicker;

  return (
    <div className="flex h-screen flex-col bg-background text-foreground">
      <AppHeader
        onMenu={() => palette.open("commands")}
        onOpenDrawer={() => setDrawerOpen(true)}
        onSettings={() => setShowSettings(true)}
        onSwitchProject={() => setShowPicker(true)}
        showDrawerButton={Boolean(state.project) && !pickerOpen && !sideVisible}
        state={state}
      />

      {showSettings && <SettingsPanel onClose={() => setShowSettings(false)} />}
      {notice && <NoticeBar notice={notice} onDismiss={() => setNotice(null)} />}
      {error && <ErrorBar error={error} onDismiss={() => setError("")} />}

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
                ? `flex w-80 shrink-0 flex-col border-(--kit-border) border-r p-3`
                : `${drawerOpen ? "flex" : "hidden"} fixed top-14 bottom-0 left-0 z-40 w-80 max-w-[85vw] flex-col border-(--kit-border) border-r bg-background p-3 shadow-lg`
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
                onOpenChangeFile={openChangeFile}
                onOpenFile={openFile}
                onRunFetch={orFail(api.runFetch)}
                onSaveFetch={thenRefresh(api.saveFetch)}
                onUndo={() => api.undo()}
                onUndoTo={orFail(api.undo)}
                onEditSchedule={(s) => scheduleFor({ target: null, editing: s })}
                onUploaded={refreshFiles}
                onCreateRunbook={thenRefresh(api.createRunbook)}
                onRunRunbook={orFail(api.runRunbook)}
                chains={chains}
                scripts={scripts}
                onCreateChain={thenRefresh(api.createChain)}
                onRunChain={orFail(api.runChain)}
                onRunScript={orFail(api.runScript)}
                onChainSteps={thenRefresh(api.chainSteps)}
                project={state.project}
                queue={queueHere}
                schedules={schedulesHere}
                reviewTick={reviewTick}
                filesRefreshing={lists.filesRefreshing}
                previewBase={state.previewBase}
                issueStamp={state.issueStamp ?? ""}
                activity={state.activity ?? null}
                pausedUntil={state.pausedUntil}
                onSchedule={(target) => scheduleFor({ target })}
                runbookTemplates={lists.runbookTemplates}
                runbooks={runbooks}
                todos={state.todos}
              />
            </div>
            <VersionLine state={state} />
          </aside>

          {/* Chat column */}
          <main className="flex min-w-0 flex-1 flex-col">
            {state.installProblem && <InstallProblem problem={state.installProblem} />}
            <div className="min-h-0 flex-1 overflow-y-auto">
              <ErrorBoundary
                area="chat view"
                context={() => ({ lastEvents: chatEvents.slice(-8).map((e) => ({ type: e.type, keys: Object.keys(e), refs: Array.isArray(e.references) ? e.references.length : undefined })) })}
                key={chatEvents.length ? chatEvents[0].seq : 0}
              >
              <Transcript
                activity={state.activity ?? null}
                look={Boolean(state.look)}
                runLive={state.runLive ?? null}
                runWindows={Array.isArray(state.runWindows) ? state.runWindows : state.runWindows ? [state.runWindows] : []}
                busy={state.busy}
                stopping={stopping}
                work={state.work ?? null}
                onStop={stop}
                onShowCopilot={() => api.showCopilot().then((r) => r.shown)}
                empty={<ChatEmpty state={state} />}
                items={transcript}
                onResendAsCoding={(text) => api.chat(text, { asCoding: true }).catch(fail)}
                onSend={(text: string, opts: ChatOptions) => api.chat(text, opts).catch(fail)}
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
                    initialEditing={scheduling.editing}
                    onClose={() => setScheduling(null)}
                    onCreate={async (spec) => {
                      await api.createSchedule(spec);
                      if (spec.kind === "chat" && spec.text === draft) setDraft("");
                    }}
                    runbooks={runbooks}
                    chains={chains}
                    scripts={scripts}
                    schedules={schedulesHere}
                  />
                )}
                <AI_Prompt
                  busy={state.busy}
                  disabled={!state.project}
                  focusKey={focusKey}
                  history={promptHistory}
                  headerLeft={<PromptHeaderLeft agent={agent} fail={setError} onAgent={setAgent} queuedNote={queuedNote} state={state} />}
                  headerRight={<PromptHeaderRight newChatPending={newChatPending} onNewChat={startNewChat} state={state} />}
                  mode={state.mode}
                  modes={MODES}
                  onAttach={() => palette.open("attach")}
                  onSchedule={(text) => setScheduling({ target: { kind: "chat", text } })}
                  clarify={clarifyFirst}
                  onToggleClarify={() => setClarifyFirst(!clarifyFirst)}
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
      {palette.element}

      {/* Once, on first use in Edge: how to put StreamHub and Copilot side by side. */}
      {state.copilot === "ready" && <SplitViewHint appWindow={state.appWindow} shownBefore={Boolean(state.hints?.splitView)} />}
      {/* File viewer */}
      {viewer && <FileViewer file={viewer} onClose={() => setViewer(null)} onOpenFile={openFile} previewBase={state.previewBase} />}
    </div>
  );
}
