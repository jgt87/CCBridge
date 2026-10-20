/** Message history in the message box (components/kokonutui/ai-prompt.tsx): Arrow Up / Down like a terminal. */

/**
 * Enter on its own sends the message. Shift+Enter makes a new line, and Enter while an input method
 * is still composing text (Japanese, Chinese, Korean: `composing`, from the event's isComposing or
 * the legacy key code 229) only confirms the composition, so it must not send.
 */
export function isSendKey(e: Pick<KeyboardEvent, "key" | "shiftKey"> & { composing?: boolean }): boolean {
  return e.key === "Enter" && !e.shiftKey && !e.composing;
}

/** An arrow key pressed on its own (with Shift, Alt, Ctrl or Meta the arrows keep their usual job). */
export function isPlainArrow(e: Pick<KeyboardEvent, "key" | "shiftKey" | "altKey" | "ctrlKey" | "metaKey">): boolean {
  const arrow = e.key === "ArrowUp" || e.key === "ArrowDown";
  const modified = e.shiftKey || e.altKey || e.ctrlKey || e.metaKey;
  return arrow && !modified;
}

/**
 * The history position an arrow key moves to, or null when it should move the cursor instead:
 * Up only from the first line and while older messages remain, Down only from the last line
 * while browsing. -1 = the text being typed; 0 = the newest earlier message.
 */
export function historyStep(
  key: string,
  el: Pick<HTMLTextAreaElement, "value" | "selectionStart" | "selectionEnd">,
  index: number,
  count: number
): number | null {
  const onFirstLine = !el.value.slice(0, el.selectionStart).includes("\n");
  const onLastLine = !el.value.slice(el.selectionEnd).includes("\n");
  // The history can shrink while browsing it (a restart, the chat history cleared): a position past
  // its end counts as the oldest message that is still there.
  const at = Math.min(index, count - 1);
  if (key === "ArrowUp" && onFirstLine && at < count - 1) return at + 1;
  if (key === "ArrowDown" && onLastLine && at >= 0) return at - 1;
  return null;
}

/** The text for a history position: the kept draft for -1, else the earlier message (0 = newest; past the end: the draft). */
export function historyText(history: string[], index: number, draft: string): string {
  return index < 0 ? draft : (history[history.length - 1 - index] ?? draft);
}
