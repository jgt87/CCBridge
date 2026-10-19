import { useEffect, useRef } from "react";
import { type AgentEvent, type AppState, api } from "@/lib/api";
import { notifyEvents, notifyQueue } from "@/lib/notify";

export interface PollHandlers {
  /** Every snapshot of the state. */
  onState: (state: AppState) => void;
  /** StreamHub was restarted while this tab stayed open: the transcript starts over. */
  onRestart: () => void;
  /** New events, in order. */
  onEvents: (events: AgentEvent[]) => void;
  /** "" after a good poll, the message after a failed one. */
  onError: (message: string) => void;
}

/** Polls the server: new events plus a state snapshot, every 400 ms. */
export function useServerPoll(handlers: PollHandlers) {
  const h = useRef(handlers);
  h.current = handlers;
  const lastSeq = useRef(0);
  const instance = useRef<string | undefined>(undefined);
  const queueSeen = useRef(new Map<string, string>());
  const pauseSeen = useRef<string | null | undefined>(undefined);

  useEffect(() => {
    let stop = false;
    let timer = 0;
    // Desktop notifications for queue changes (the first poll only records the current state).
    const noteQueue = (state: AppState) => {
      const q = state.queue ?? [];
      if (pauseSeen.current === undefined) queueSeen.current = new Map(q.map((x) => [x.id, x.status]));
      else queueSeen.current = notifyQueue(queueSeen.current, q, pauseSeen.current, state.pausedUntil);
      pauseSeen.current = state.pausedUntil ?? null;
    };
    const tick = async () => {
      try {
        const r = await api.poll(lastSeq.current);
        // StreamHub was restarted while this tab stayed open (the token survives a restart): its
        // event numbers start over, so the transcript starts over and the next poll reads from 0.
        if (r.state.instance && r.state.instance !== instance.current) {
          const restarted = instance.current !== undefined;
          instance.current = r.state.instance;
          if (restarted) {
            lastSeq.current = 0;
            h.current.onRestart();
            h.current.onState(r.state);
            if (!stop) timer = window.setTimeout(tick, 0);
            return;
          }
        }
        h.current.onState(r.state);
        noteQueue(r.state);
        if (r.events.length) {
          lastSeq.current = r.events[r.events.length - 1].seq;
          h.current.onEvents(r.events);
          notifyEvents(r.events);
        }
        h.current.onError("");
      } catch (e) {
        h.current.onError(`Lost contact with StreamHub: ${(e as Error).message}. Is the PowerShell window still open?`);
      }
      if (!stop) timer = window.setTimeout(tick, 400);
    };
    tick();
    return () => {
      stop = true;
      clearTimeout(timer);
    };
  }, []);
}
