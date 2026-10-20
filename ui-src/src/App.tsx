import { useCallback, useEffect, useMemo, useState } from "react";
import AI_Prompt from "@/components/kokonutui/ai-prompt";
import { SettingsPanel } from "@/components/ccb/settings-panel";
import { SidePanel } from "@/components/ccb/side-panel";
import type { ScheduleTarget } from "@/components/ccb/schedule-form";
import { SchedulesModal } from "@/components/ccb/schedules-modal";
import { FileViewer } from "@/components/ccb/file-viewer";
import { SplitViewHint } from "@/components/ccb/split-view-hint";
import { AppHeader, ErrorBar, InstallProblem, NoticeBar, PromptHeaderLeft, PromptHeaderRight, VersionLine } from "@/components/ccb/app-chrome";
import { ChatTranscript, PickerView, SideDrawer } from "@/components/ccb/app-layout";
import { MODES, type Notice, useCommandPalette } from "@/components/ccb/command-palette";
import { buildTranscript } from "@/components/ccb/transcript";
import { useChatActions } from "@/hooks/use-chat-actions";
import { useFileViewer } from "@/hooks/use-file-viewer";
import { useProjectLists } from "@/hooks/use-project-lists";
import { useServerPoll } from "@/hooks/use-server-poll";
import { useSideDrawer } from "@/hooks/use-side-drawer";
import { useSidePanelActions } from "@/hooks/use-side-panel-actions";
import { useStoredChoice } from "@/hooks/use-stored-choice";
import { useWorkTitle } from "@/hooks/use-work-title";
import { parseAgent, parseClarify, showAgent, showClarify } from "@/lib/app-view";
import { changeSets, chatView, endsNewChat, inProject, keptView, projectKey, projectView, promptHistory as promptHistoryOf, touchesFiles, touchesReview } from "@/lib/event-views";
import { prefetchSettings } from "@/lib/settings-cache";
import { setLinksThroughEdge } from "@/lib/links";
import type { ScheduleItem } from "@/lib/api";
import { type AgentEvent, type AppState, api, type Mode } from "@/lib/api";

const EMPTY_STATE: AppState = {
  project: null, mode: "ask", busy: false, progress: "", copilot: "idle", copilotMessage: "",
  throttle: { used: 0, max: 0 }, credits: null, todos: [], promptLimit: 0,
  workIq: "leave", workIqActual: null, workIqAvailable: false, logLevel: "info", version: "",
};

export default function App() {
  const [state, setState] = useState<AppState>(EMPTY_STATE);
  const [events, setEvents] = useState<AgentEvent[]>([]);
  // Schedules modal: closed (null), the list ({ target: null }) or a form for a target.
  const [scheduling, setScheduling] = useState<{ target: ScheduleTarget | null; editing?: ScheduleItem } | null>(null);
  const [reviewTick, setReviewTick] = useState(0);
  // Remembered in this browser: Clarify first, and who answers the next message (lib/app-view.ts).
  const [clarifyFirst, setClarifyFirst] = useStoredChoice("ccb.clarify", parseClarify, showClarify);
  const [agent, setAgent] = useStoredChoice("ccb.agent", parseAgent, showAgent);
  const [showPicker, setShowPicker] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState<Notice | null>(null);
  const [showSettings, setShowSettings] = useState(false);
  const { wide, drawerOpen, setDrawerOpen, sideVisible } = useSideDrawer();
  const lists = useProjectLists(state.project?.path, state.busy);
  const { files, fetchItems, runbooks, chains, scripts, refreshFiles } = lists;
  const fail = useCallback((e: unknown) => setError((e as Error).message), []);
  const chat = useChatActions({ busy: state.busy, agent, clarify: clarifyFirst, fail });
  const { viewer, closeViewer, openFile, openChangeFile } = useFileViewer(() => setDrawerOpen(false), fail);
  const sideActions = useSidePanelActions(fail, refreshFiles);

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
      chat.onState(s.busy);
    },
    onRestart: () => setEvents([]),
    onEvents: (evs) => {
      setEvents((prev) => [...prev, ...evs]);
      if (touchesFiles(evs)) refreshFiles();
      if (touchesReview(evs)) setReviewTick((t) => t + 1);
      if (endsNewChat(evs)) chat.newChatDone();
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

  const palette = useCommandPalette({
    state,
    files,
    fetchItems,
    attachPath: chat.attachPath,
    openFile,
    startNewChat: chat.startNewChat,
    openSettings: () => setShowSettings(true),
    openPicker: () => setShowPicker(true),
    setLogLevel: (level) => setState((s) => ({ ...s, logLevel: level })),
    notice: setNotice,
    fail: setError,
  });

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
        <PickerView onClose={() => setShowPicker(false)} project={state.project} />
      ) : (
        <div className="flex min-h-0 flex-1">
          {/* Side panel (left) */}
          <SideDrawer footer={<VersionLine state={state} />} onClose={() => setDrawerOpen(false)} open={drawerOpen} wide={wide}>
            <SidePanel
              key={state.project?.path ?? "none"}
              {...sideActions}
              busy={state.busy}
              changes={changes}
              fetchItems={fetchItems}
              files={files}
              onAttach={chat.attachPath}
              onOpenChangeFile={openChangeFile}
              onOpenFile={openFile}
              onEditSchedule={(s) => scheduleFor({ target: null, editing: s })}
              chains={chains}
              scripts={scripts}
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
          </SideDrawer>

          {/* Chat column */}
          <main className="flex min-w-0 flex-1 flex-col">
            {state.installProblem && <InstallProblem problem={state.installProblem} />}
            <div className="min-h-0 flex-1 overflow-y-auto">
              <ChatTranscript
                chatEvents={chatEvents}
                fail={fail}
                items={transcript}
                onOpenFile={openFile}
                onStop={chat.stop}
                onUsePrompt={chat.fillPrompt}
                state={state}
                stopping={chat.stopping}
              />
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
                      if (spec.kind === "chat" && spec.text === chat.draft) chat.setDraft("");
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
                  focusKey={chat.focusKey}
                  history={promptHistory}
                  headerLeft={<PromptHeaderLeft agent={agent} fail={setError} onAgent={setAgent} queuedNote={chat.queuedNote} state={state} />}
                  headerRight={<PromptHeaderRight newChatPending={chat.newChatPending} onNewChat={chat.startNewChat} state={state} />}
                  mode={state.mode}
                  modes={MODES}
                  onAttach={() => palette.open("attach")}
                  onSchedule={(text) => setScheduling({ target: { kind: "chat", text } })}
                  clarify={clarifyFirst}
                  onToggleClarify={() => setClarifyFirst(!clarifyFirst)}
                  onModeChange={(m) => api.setMode(m as Mode)}
                  onStop={chat.stop}
                  onSubmit={chat.send}
                  onValueChange={chat.setDraft}
                  placeholder="Ask Copilot to build or change something..."
                  value={chat.draft}
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
      {viewer && <FileViewer file={viewer} onClose={closeViewer} onOpenFile={openFile} previewBase={state.previewBase} />}
    </div>
  );
}
