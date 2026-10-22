import { useMemo } from "react";
import { buildTranscript } from "@/components/ccb/transcript";
import type { AgentEvent, AppState } from "@/lib/api";
import { changeSets, chatView, inProject, keptView, projectKey, projectView, promptHistory as promptHistoryOf } from "@/lib/event-views";

/** What the app shows from the server's events and state (lib/event-views.ts): the chat, its
 *  transcript, the prompt history, the change sets, and the open project's queue and schedules. */
export function useEventViews(events: AgentEvent[], state: AppState) {
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
  return { chatEvents, transcript, promptHistory, changes, queueHere, schedulesHere };
}
