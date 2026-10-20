import { useState } from "react";
import type { AgentChoice } from "@/components/ccb/app-chrome";
import { api } from "@/lib/api";
import { sendOptions, withAttached } from "@/lib/app-view";

/** The message box and what the chat does: send, stop, a new chat, @-attach a file, use a suggested prompt. */
export function useChatActions({ busy, agent, clarify, fail }: { busy: boolean; agent: AgentChoice; clarify: boolean; fail: (e: unknown) => void }) {
  const [draft, setDraft] = useState("");
  const [focusKey, setFocusKey] = useState(0);
  const [queuedNote, setQueuedNote] = useState(false);
  const [newChatPending, setNewChatPending] = useState(false);
  const [stopping, setStopping] = useState(false);

  const startNewChat = () => {
    setNewChatPending(true);
    if (busy) setStopping(true);
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
      await api.chat(text, sendOptions(agent, clarify));
      setDraft("");
      // Sent while busy = queued: say when it runs (only while StreamHub stays open).
      if (busy) {
        setQueuedNote(true);
        window.setTimeout(() => setQueuedNote(false), 8000);
      }
    } catch (e) {
      fail(e);
    }
  };

  const attachPath = (path: string) => {
    setDraft((d) => withAttached(d, path));
    setFocusKey((k) => k + 1);
  };

  const fillPrompt = (text: string) => {
    setDraft(text);
    setFocusKey((k) => k + 1);
  };

  return {
    draft,
    setDraft,
    focusKey,
    queuedNote,
    newChatPending,
    stopping,
    startNewChat,
    stop,
    send,
    attachPath,
    fillPrompt,
    /** The server's state came in: a task that is no longer busy is no longer stopping. */
    onState: (nowBusy: boolean) => {
      if (!nowBusy) setStopping(false);
    },
    /** The new chat has opened (its event came in). */
    newChatDone: () => setNewChatPending(false),
  };
}
