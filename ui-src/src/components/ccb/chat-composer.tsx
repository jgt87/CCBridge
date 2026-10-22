import AI_Prompt from "@/components/kokonutui/ai-prompt";
import { type AgentChoice, PromptHeaderLeft, PromptHeaderRight } from "@/components/ccb/app-chrome";
import { MODES } from "@/components/ccb/command-palette";
import type { ScheduleTarget } from "@/components/ccb/schedule-form";
import { SchedulesModal } from "@/components/ccb/schedules-modal";
import type { useChatActions } from "@/hooks/use-chat-actions";
import type { useProjectLists } from "@/hooks/use-project-lists";
import { type AppState, api, type Mode, type ScheduleItem } from "@/lib/api";

/** The schedules modal: closed (null), the list ({ target: null }) or a form for a target. */
export type Scheduling = { target: ScheduleTarget | null; editing?: ScheduleItem } | null;

/** The message box under the chat, with the schedules modal above it when open. */
export function ChatComposer({
  state,
  chat,
  lists,
  schedules,
  history,
  scheduling,
  onScheduling,
  agent,
  onAgent,
  clarify,
  onClarify,
  onAttach,
  fail,
}: {
  state: AppState;
  chat: ReturnType<typeof useChatActions>;
  lists: ReturnType<typeof useProjectLists>;
  schedules: ScheduleItem[];
  history: string[];
  scheduling: Scheduling;
  onScheduling: (s: Scheduling) => void;
  agent: AgentChoice;
  onAgent: (a: AgentChoice) => void;
  clarify: boolean;
  onClarify: (on: boolean) => void;
  onAttach: () => void;
  fail: (message: string) => void;
}) {
  return (
    <div className="shrink-0 px-4">
      <div className="mx-auto max-w-[max(48rem,80%)]">
        {scheduling && (
          <SchedulesModal
            fetchItems={lists.fetchItems}
            files={lists.files}
            initial={scheduling.target}
            initialEditing={scheduling.editing}
            onClose={() => onScheduling(null)}
            onCreate={async (spec) => {
              await api.createSchedule(spec);
              if (spec.kind === "chat" && spec.text === chat.draft) chat.setDraft("");
            }}
            runbooks={lists.runbooks}
            chains={lists.chains}
            scripts={lists.scripts}
            schedules={schedules}
          />
        )}
        <AI_Prompt
          busy={state.busy}
          disabled={!state.project}
          focusKey={chat.focusKey}
          history={history}
          headerLeft={<PromptHeaderLeft agent={agent} fail={fail} onAgent={onAgent} queuedNote={chat.queuedNote} state={state} />}
          headerRight={<PromptHeaderRight newChatPending={chat.newChatPending} onNewChat={chat.startNewChat} state={state} />}
          mode={state.mode}
          modes={MODES}
          onAttach={onAttach}
          onSchedule={(text) => onScheduling({ target: { kind: "chat", text } })}
          clarify={clarify}
          onToggleClarify={() => onClarify(!clarify)}
          onModeChange={(m) => api.setMode(m as Mode)}
          onStop={chat.stop}
          onSubmit={chat.send}
          onValueChange={chat.setDraft}
          placeholder="Ask Copilot to build or change something..."
          value={chat.draft}
        />
      </div>
    </div>
  );
}
