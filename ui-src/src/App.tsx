import { useCallback, useState } from "react";
import { SettingsPanel } from "@/components/ccb/settings-panel";
import { SidePanel } from "@/components/ccb/side-panel";
import { FileViewer } from "@/components/ccb/file-viewer";
import { SplitViewHint } from "@/components/ccb/split-view-hint";
import { AppHeader, ErrorBar, InstallProblem, NoticeBar, VersionLine } from "@/components/ccb/app-chrome";
import { ChatTranscript, PickerView, SideDrawer } from "@/components/ccb/app-layout";
import { ChatComposer, type Scheduling } from "@/components/ccb/chat-composer";
import { type Notice, useCommandPalette } from "@/components/ccb/command-palette";
import { useAppSetup } from "@/hooks/use-app-setup";
import { useChatActions } from "@/hooks/use-chat-actions";
import { useEventViews } from "@/hooks/use-event-views";
import { useFileViewer } from "@/hooks/use-file-viewer";
import { useProjectLists } from "@/hooks/use-project-lists";
import { useServerPoll } from "@/hooks/use-server-poll";
import { useSideDrawer } from "@/hooks/use-side-drawer";
import { useSidePanelActions } from "@/hooks/use-side-panel-actions";
import { useStoredChoice } from "@/hooks/use-stored-choice";
import { useWorkTitle } from "@/hooks/use-work-title";
import { parseAgent, parseClarify, showAgent, showClarify } from "@/lib/app-view";
import { endsNewChat, touchesFiles, touchesReview } from "@/lib/event-views";
import type { AgentEvent, AppState } from "@/lib/api";

const EMPTY_STATE: AppState = {
  project: null, mode: "ask", busy: false, progress: "", copilot: "idle", copilotMessage: "",
  throttle: { used: 0, max: 0 }, credits: null, todos: [], promptLimit: 0,
  workIq: "leave", workIqActual: null, workIqAvailable: false, logLevel: "info", version: "",
};

export default function App() {
  const [state, setState] = useState<AppState>(EMPTY_STATE);
  const [events, setEvents] = useState<AgentEvent[]>([]);
  const [scheduling, setScheduling] = useState<Scheduling>(null);
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

  useAppSetup(state.appInEdge);

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

  const views = useEventViews(events, state);

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

  const scheduleFor = (s: Scheduling) => {
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
              changes={views.changes}
              fetchItems={fetchItems}
              files={files}
              onAttach={chat.attachPath}
              onOpenChangeFile={openChangeFile}
              onOpenFile={openFile}
              onEditSchedule={(s) => scheduleFor({ target: null, editing: s })}
              chains={chains}
              scripts={scripts}
              project={state.project}
              queue={views.queueHere}
              schedules={views.schedulesHere}
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
                chatEvents={views.chatEvents}
                fail={fail}
                items={views.transcript}
                onOpenFile={openFile}
                onStop={chat.stop}
                onUsePrompt={chat.fillPrompt}
                state={state}
                stopping={chat.stopping}
              />
            </div>
            <ChatComposer
              agent={agent}
              chat={chat}
              clarify={clarifyFirst}
              fail={setError}
              history={views.promptHistory}
              lists={lists}
              onAgent={setAgent}
              onAttach={() => palette.open("attach")}
              onClarify={setClarifyFirst}
              onScheduling={setScheduling}
              schedules={views.schedulesHere}
              scheduling={scheduling}
              state={state}
            />
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
