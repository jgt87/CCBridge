"use client";

/**
 * @author: @kokonutui
 * @description: AI Prompt Input
 * @version: 1.0.0
 * @date: 2025-06-26
 * @license: MIT
 * @website: https://kokonutui.com
 * @github: https://github.com/kokonut-labs/kokonutui
 *
 * CCBridge: the model selector became the agent mode selector (ask / auto / plan),
 * the paperclip attaches a project file as @path, and the value is controlled by the parent.
 */

import { ArrowRight, AtSign, CalendarClock, Check, ChevronDown, MessageCircleQuestion, Square } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Textarea } from "@/components/ui/textarea";
import { useAutoResizeTextarea } from "@/hooks/use-auto-resize-textarea";
import { cn } from "@/lib/utils";

export interface PromptMode {
  id: string;
  label: string;
  description: string;
  icon: React.ReactNode;
}

interface AIPromptProps {
  modes: PromptMode[];
  mode: string;
  onModeChange: (id: string) => void;
  value: string;
  onValueChange: (value: string) => void;
  onSubmit: (value: string) => void;
  onAttach?: () => void;
  /** CCBridge: schedule the typed message instead of sending it now. */
  onSchedule?: (value: string) => void;
  /** CCBridge: "Clarify first" (Copilot asks questions, then plans, before building). */
  clarify?: boolean;
  onToggleClarify?: () => void;
  onStop?: () => void;
  busy?: boolean;
  disabled?: boolean;
  placeholder?: string;
  headerLeft?: React.ReactNode;
  headerRight?: React.ReactNode;
  className?: string;
  focusKey?: number;
  /** Earlier messages, oldest first: Arrow Up / Down in the box steps through them. */
  history?: string[];
}

/** Hover and focus look shared by the buttons in the bar under the message box. */
const BAR_BUTTON = "hover:bg-black/10 focus-visible:ring-1 focus-visible:ring-zinc-400 focus-visible:ring-offset-0 dark:hover:bg-white/10";
const TOOL_IDLE = "bg-black/5 text-black/40 hover:text-black dark:bg-white/5 dark:text-white/40 dark:hover:text-white";

// --- Message history (CCBridge): Arrow Up / Down like a terminal ---------------------------

/** An arrow key pressed on its own (with Shift, Alt, Ctrl or Meta the arrows keep their usual job). */
function isPlainArrow(e: React.KeyboardEvent) {
  const arrow = e.key === "ArrowUp" || e.key === "ArrowDown";
  const modified = e.shiftKey || e.altKey || e.ctrlKey || e.metaKey;
  return arrow && !modified;
}

/**
 * The history position an arrow key moves to, or null when it should move the cursor instead:
 * Up only from the first line and while older messages remain, Down only from the last line
 * while browsing. -1 = the text being typed; 0 = the newest earlier message.
 */
function historyStep(key: string, el: HTMLTextAreaElement, index: number, count: number): number | null {
  const onFirstLine = !el.value.slice(0, el.selectionStart).includes("\n");
  const onLastLine = !el.value.slice(el.selectionEnd).includes("\n");
  if (key === "ArrowUp" && onFirstLine && index < count - 1) return index + 1;
  if (key === "ArrowDown" && onLastLine && index >= 0) return index - 1;
  return null;
}

// --- Parts of the bar under the message box --------------------------------------------------

/** The agent mode picker (ask / auto / plan). */
function ModeMenu({ modes, selected, onModeChange }: { modes: PromptMode[]; selected: PromptMode; onModeChange: (id: string) => void }) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger render={<Button className={cn("flex h-8 items-center gap-1 rounded-md pr-2 pl-1 text-xs dark:text-white", BAR_BUTTON)} variant="ghost" />}>
        <AnimatePresence mode="wait">
          <motion.div
            animate={{ opacity: 1, y: 0 }}
            className="flex items-center gap-1.5"
            exit={{ opacity: 0, y: 5 }}
            initial={{ opacity: 0, y: -5 }}
            key={selected.id}
            transition={{ duration: 0.15 }}
          >
            {selected.icon}
            {selected.label}
            <ChevronDown className="h-3 w-3 opacity-50" />
          </motion.div>
        </AnimatePresence>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        className={cn(
          "min-w-[16rem]",
          "border-black/10 dark:border-white/10",
          "bg-gradient-to-b from-white via-white to-neutral-100 dark:from-neutral-950 dark:via-neutral-900 dark:to-neutral-800"
        )}
      >
        {modes.map((m) => (
          <DropdownMenuItem className="flex items-start justify-between gap-3 py-2" key={m.id} onClick={() => onModeChange(m.id)}>
            <div className="flex items-start gap-2">
              <span className="mt-0.5">{m.icon}</span>
              <span className="flex flex-col">
                <span>{m.label}</span>
                <span className="text-muted-foreground text-xs">{m.description}</span>
              </span>
            </div>
            {selected.id === m.id && <Check className="mt-0.5 h-4 w-4 text-foreground" />}
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

/** An icon button in the bar (attach, clarify, schedule); `pressed` shows a toggle that is on. */
function ToolButton({
  label,
  title,
  onClick,
  pressed,
  children,
}: {
  label: string;
  title: string;
  onClick?: () => void;
  pressed?: boolean;
  children: React.ReactNode;
}) {
  return (
    <button
      aria-label={label}
      aria-pressed={pressed}
      className={cn("cursor-pointer rounded-lg p-2", BAR_BUTTON, pressed ? "bg-black/15 text-black dark:bg-white/20 dark:text-white" : TOOL_IDLE)}
      onClick={onClick}
      title={title}
      type="button"
    >
      {children}
    </button>
  );
}

/** Queue (while busy and there is text), then Stop while busy or Send otherwise. */
function SendControls({ busy, canSend, onSubmit, onStop }: { busy: boolean; canSend: boolean; onSubmit: () => void; onStop?: () => void }) {
  return (
    <div className="flex items-center gap-1.5">
      {busy && canSend && (
        <button
          aria-label="Add to the queue"
          className="h-8 rounded-lg bg-black/5 px-2.5 text-xs hover:bg-black/10 dark:bg-white/5 dark:text-white dark:hover:bg-white/10"
          onClick={onSubmit}
          title="Add to the queue: runs after the current task (Enter)"
          type="button"
        >
          Queue
        </button>
      )}
      {busy ? (
        <button aria-label="Stop" className={cn("rounded-lg bg-black/5 p-2 dark:bg-white/5", BAR_BUTTON)} onClick={onStop} title="Stop after the current step" type="button">
          <Square className="h-4 w-4 fill-current dark:text-white" />
        </button>
      ) : (
        <button aria-label="Send message" className={cn("rounded-lg bg-black/5 p-2 dark:bg-white/5", BAR_BUTTON)} disabled={!canSend} onClick={onSubmit} type="button">
          <ArrowRight className={cn("h-4 w-4 transition-opacity duration-200 dark:text-white", canSend ? "opacity-100" : "opacity-30")} />
        </button>
      )}
    </div>
  );
}

// --- The prompt ------------------------------------------------------------------------------

export default function AI_Prompt({
  modes,
  mode,
  onModeChange,
  value,
  onValueChange,
  onSubmit,
  onAttach,
  onSchedule,
  clarify = false,
  onToggleClarify,
  onStop,
  busy = false,
  disabled = false,
  placeholder = "What can I do for you?",
  headerLeft,
  headerRight,
  className,
  focusKey,
  history = [],
}: AIPromptProps) {
  const { textareaRef, adjustHeight } = useAutoResizeTextarea({
    minHeight: 72,
    maxHeight: 300,
  });
  const selected = modes.find((m) => m.id === mode) ?? modes[0];
  // CCBridge: while Copilot is busy, sending adds the message to the queue.
  const canSend = !disabled && value.trim().length > 0;

  useEffect(() => {
    adjustHeight();
  }, [value, adjustHeight]);

  useEffect(() => {
    if (focusKey) textareaRef.current?.focus();
  }, [focusKey, textareaRef]);

  const submit = () => {
    if (!canSend) return;
    onSubmit(value);
    adjustHeight(true);
  };

  // CCBridge: message history like a terminal. -1 = the text being typed (kept in `draftRef`);
  // 0 = the newest earlier message, 1 = the one before, and so on.
  const [historyIndex, setHistoryIndex] = useState(-1);
  const draftRef = useRef("");
  const recall = (index: number) => {
    setHistoryIndex(index);
    const text = index < 0 ? draftRef.current : history[history.length - 1 - index];
    onValueChange(text);
    // Cursor to the end, after React has put the text in the box.
    requestAnimationFrame(() => {
      const el = textareaRef.current;
      if (el) el.setSelectionRange(el.value.length, el.value.length);
    });
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      setHistoryIndex(-1);
      submit();
      return;
    }
    if (!isPlainArrow(e) || !history.length) return;
    const next = historyStep(e.key, e.currentTarget, historyIndex, history.length);
    if (next === null) return;
    e.preventDefault();
    if (historyIndex < 0) draftRef.current = e.currentTarget.value; // leaving the typed text: keep it
    recall(next);
  };

  return (
    <div className={cn("w-full py-4", className)}>
      <div className="rounded-2xl bg-black/5 p-1.5 pt-4 dark:bg-white/5">
        <div className="mx-2 mb-2.5 flex items-center gap-2">
          <div className="flex min-w-0 flex-1 items-center gap-2 text-black text-xs tracking-tighter dark:text-white/90">
            {headerLeft}
          </div>
          <div className="text-black text-xs tracking-tighter dark:text-white/90">
            {headerRight}
          </div>
        </div>
        <div className="relative">
          <div className="relative flex flex-col">
            <div className="overflow-y-auto" style={{ maxHeight: "400px" }}>
              <Textarea
                className={cn(
                  "w-full resize-none rounded-xl rounded-b-none border-none bg-black/5 px-4 py-3 placeholder:text-black/70 focus-visible:ring-0 focus-visible:ring-offset-0 dark:bg-white/5 dark:text-white dark:placeholder:text-white/50",
                  "min-h-[72px]"
                )}
                disabled={disabled}
                id="ccb-prompt"
                onChange={(e) => {
                  setHistoryIndex(-1);
                  onValueChange(e.target.value);
                }}
                onKeyDown={handleKeyDown}
                placeholder={placeholder}
                ref={textareaRef}
                value={value}
              />
            </div>

            <div className="flex h-14 items-center rounded-b-xl bg-black/5 dark:bg-white/5">
              <div className="absolute right-3 bottom-3 left-3 flex w-[calc(100%-24px)] items-center justify-between">
                <div className="flex items-center gap-2">
                  <ModeMenu modes={modes} onModeChange={onModeChange} selected={selected} />
                  <div className="mx-0.5 h-4 w-px bg-black/10 dark:bg-white/10" />
                  <ToolButton label="Attach a project file" onClick={onAttach} title="Attach a project file (@path)">
                    <AtSign className="h-4 w-4 transition-colors" />
                  </ToolButton>
                  {onToggleClarify && (
                    <ToolButton
                      label="Clarify first"
                      onClick={onToggleClarify}
                      pressed={clarify}
                      title={clarify ? "Clarify first is on: Copilot asks its questions and makes a plan for you to approve before it builds" : "Clarify first: Copilot asks its questions and makes a plan for you to approve before it builds"}
                    >
                      <MessageCircleQuestion className="h-4 w-4 transition-colors" />
                    </ToolButton>
                  )}
                  {onSchedule && (
                    <ToolButton label="Schedule this message" onClick={() => onSchedule(value)} title="Schedule: send this message (or run a runbook or fetch) on set days and times">
                      <CalendarClock className="h-4 w-4 transition-colors" />
                    </ToolButton>
                  )}
                </div>
                {/* CCBridge: Queue (while busy) sits right next to Stop / Send. */}
                <SendControls busy={busy} canSend={canSend} onStop={onStop} onSubmit={submit} />
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
