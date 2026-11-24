import { type ReactNode, useEffect, useRef } from "react";
import { focusableIn, keepFocusInside } from "@/lib/focus-trap";
import { ErrorBoundary } from "@/components/ccb/error-boundary";
import { ChatEmpty, SIDE_PANEL_ID } from "@/components/ccb/app-chrome";
import { ProjectPicker } from "@/components/ccb/project-picker";
import { Transcript, type TranscriptItem } from "@/components/ccb/transcript";
import { type AgentEvent, type AppState, type ChatOptions, api } from "@/lib/api";
import { runWindowList } from "@/lib/app-view";

/** The project list, with a way back to the open project. */
export function PickerView({ project, onClose }: { project: AppState["project"]; onClose: () => void }) {
  return (
    <main className="flex-1 overflow-y-auto" id="main" tabIndex={-1}>
      {project && (
        <div className="mx-auto max-w-xl px-4 pt-6">
          <button className="text-muted-foreground text-sm hover:text-foreground" onClick={onClose} type="button">
            ← Back to {project.name}
          </button>
        </div>
      )}
      <ProjectPicker onOpened={onClose} />
    </main>
  );
}

/** The side panel's place: beside the chat on a wide window, else a drawer over it. */
export function SideDrawer({ wide, open, onClose, footer, children }: { wide: boolean; open: boolean; onClose: () => void; footer: ReactNode; children: ReactNode }) {
  const ref = useRef<HTMLElement>(null);
  const overlay = !wide && open;
  // Over the chat it is a modal dialog: focus moves into it, Tab stays inside, and on close focus goes
  // back to the button that opened it (shown again once the panel is closed).
  useEffect(() => {
    if (!overlay || !ref.current) return;
    (focusableIn(ref.current)[0] ?? ref.current).focus({ preventScroll: true });
    const panel = ref.current;
    return () => {
      window.requestAnimationFrame(() => {
        // Only when focus was left in the closed panel (or lost): a file or form opened from it keeps it.
        const active = document.activeElement;
        if (active && active !== document.body && !panel.contains(active)) return;
        document.querySelector<HTMLElement>(`[aria-controls="${SIDE_PANEL_ID}"]`)?.focus({ preventScroll: true });
      });
    };
  }, [overlay]);
  return (
    <>
      {/* The chat is not dimmed: a click beside the open panel only closes it. */}
      {overlay && <div aria-hidden className="fixed inset-0 top-14 z-30" onClick={onClose} />}
      <aside
        aria-label="Side panel"
        aria-modal={overlay || undefined}
        id={SIDE_PANEL_ID}
        onKeyDown={overlay ? keepFocusInside : undefined}
        ref={ref}
        role={overlay ? "dialog" : undefined}
        tabIndex={overlay ? -1 : undefined}
        className={
          wide
            ? `flex w-80 shrink-0 flex-col border-(--kit-border) border-r p-3`
            : `${open ? "flex" : "hidden"} fixed top-14 bottom-0 left-0 z-40 w-80 max-w-[85vw] flex-col border-(--kit-border) border-r bg-background p-3 shadow-lg`
        }
      >
        <div className="min-h-0 flex-1">{children}</div>
        {footer}
      </aside>
    </>
  );
}

/** The chat transcript in its error boundary, fed from the server's state. */
export function ChatTranscript({
  state,
  chatEvents,
  items,
  stopping,
  onStop,
  onOpenFile,
  onUsePrompt,
  fail,
}: {
  state: AppState;
  chatEvents: AgentEvent[];
  items: TranscriptItem[];
  stopping: boolean;
  onStop: () => void;
  onOpenFile: (path: string) => void;
  onUsePrompt: (text: string) => void;
  fail: (e: unknown) => void;
}) {
  return (
    <ErrorBoundary
      area="chat view"
      context={() => ({ lastEvents: chatEvents.slice(-8).map((e) => ({ type: e.type, keys: Object.keys(e), refs: Array.isArray(e.references) ? e.references.length : undefined })) })}
      key={chatEvents.length ? chatEvents[0].seq : 0}
    >
      <Transcript
        activity={state.activity ?? null}
        look={Boolean(state.look)}
        runLive={state.runLive ?? null}
        runWindows={runWindowList(state.runWindows)}
        busy={state.busy}
        stopping={stopping}
        work={state.work ?? null}
        onStop={onStop}
        onShowCopilot={() => api.showCopilot().then((r) => r.shown)}
        empty={<ChatEmpty state={state} />}
        items={items}
        onResendAsCoding={(text) => api.chat(text, { asCoding: true }).catch(fail)}
        onSend={(text: string, opts: ChatOptions) => api.chat(text, opts).catch(fail)}
        onOpenFile={onOpenFile}
        onUsePrompt={onUsePrompt}
        progress={state.progress}
      />
    </ErrorBoundary>
  );
}
