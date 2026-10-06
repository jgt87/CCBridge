/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui ai-prompt (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */
import { type ReactNode, useState } from "react";

/** A text box with an action row under it; Ctrl+Enter sends. */
export function Composer({
  onSend,
  placeholder = "Write a message",
  sendLabel = "Send",
  actions,
  label = "Message",
}: {
  onSend: (text: string) => void;
  placeholder?: string;
  sendLabel?: string;
  actions?: ReactNode;
  label?: string;
}) {
  const [text, setText] = useState("");
  const send = () => {
    if (!text.trim()) return;
    onSend(text.trim());
    setText("");
  };
  return (
    <div className="kit-composer">
      <textarea
        aria-label={label}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
            e.preventDefault();
            send();
          }
        }}
        placeholder={placeholder}
        value={text}
      />
      <div className="kit-composer__actions">
        {actions}
        <span className="kit-toolbar__spacer" />
        <button className="kit-btn kit-btn--primary kit-btn--sm" disabled={!text.trim()} onClick={send} type="button">
          {sendLabel}
        </button>
      </div>
    </div>
  );
}
