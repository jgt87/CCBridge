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

import { ArrowRight, AtSign, Check, ChevronDown, Square } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { useEffect } from "react";
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
  onStop?: () => void;
  busy?: boolean;
  disabled?: boolean;
  placeholder?: string;
  headerLeft?: React.ReactNode;
  headerRight?: React.ReactNode;
  className?: string;
  focusKey?: number;
}

export default function AI_Prompt({
  modes,
  mode,
  onModeChange,
  value,
  onValueChange,
  onSubmit,
  onAttach,
  onStop,
  busy = false,
  disabled = false,
  placeholder = "What can I do for you?",
  headerLeft,
  headerRight,
  className,
  focusKey,
}: AIPromptProps) {
  const { textareaRef, adjustHeight } = useAutoResizeTextarea({
    minHeight: 72,
    maxHeight: 300,
  });
  const selected = modes.find((m) => m.id === mode) ?? modes[0];
  const canSend = !busy && !disabled && value.trim().length > 0;

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

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
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
                onChange={(e) => onValueChange(e.target.value)}
                onKeyDown={handleKeyDown}
                placeholder={placeholder}
                ref={textareaRef}
                value={value}
              />
            </div>

            <div className="flex h-14 items-center rounded-b-xl bg-black/5 dark:bg-white/5">
              <div className="absolute right-3 bottom-3 left-3 flex w-[calc(100%-24px)] items-center justify-between">
                <div className="flex items-center gap-2">
                  <DropdownMenu>
                    <DropdownMenuTrigger render={<Button className="flex h-8 items-center gap-1 rounded-md pr-2 pl-1 text-xs hover:bg-black/10 focus-visible:ring-1 focus-visible:ring-zinc-400 focus-visible:ring-offset-0 dark:text-white dark:hover:bg-white/10" variant="ghost" />}>
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
                        <DropdownMenuItem
                          className="flex items-start justify-between gap-3 py-2"
                          key={m.id}
                          onClick={() => onModeChange(m.id)}
                        >
                          <div className="flex items-start gap-2">
                            <span className="mt-0.5">{m.icon}</span>
                            <span className="flex flex-col">
                              <span>{m.label}</span>
                              <span className="text-muted-foreground text-xs">{m.description}</span>
                            </span>
                          </div>
                          {selected.id === m.id && (
                            <Check className="mt-0.5 h-4 w-4 text-foreground" />
                          )}
                        </DropdownMenuItem>
                      ))}
                    </DropdownMenuContent>
                  </DropdownMenu>
                  <div className="mx-0.5 h-4 w-px bg-black/10 dark:bg-white/10" />
                  <button
                    aria-label="Attach a project file"
                    className={cn(
                      "cursor-pointer rounded-lg bg-black/5 p-2 dark:bg-white/5",
                      "hover:bg-black/10 focus-visible:ring-1 focus-visible:ring-zinc-400 focus-visible:ring-offset-0 dark:hover:bg-white/10",
                      "text-black/40 hover:text-black dark:text-white/40 dark:hover:text-white"
                    )}
                    onClick={onAttach}
                    title="Attach a project file (@path)"
                    type="button"
                  >
                    <AtSign className="h-4 w-4 transition-colors" />
                  </button>
                </div>
                {busy ? (
                  <button
                    aria-label="Stop"
                    className={cn(
                      "rounded-lg bg-black/5 p-2 dark:bg-white/5",
                      "hover:bg-black/10 focus-visible:ring-1 focus-visible:ring-zinc-400 focus-visible:ring-offset-0 dark:hover:bg-white/10"
                    )}
                    onClick={onStop}
                    title="Stop after the current step"
                    type="button"
                  >
                    <Square className="h-4 w-4 fill-current dark:text-white" />
                  </button>
                ) : (
                  <button
                    aria-label="Send message"
                    className={cn(
                      "rounded-lg bg-black/5 p-2 dark:bg-white/5",
                      "hover:bg-black/10 focus-visible:ring-1 focus-visible:ring-zinc-400 focus-visible:ring-offset-0 dark:hover:bg-white/10"
                    )}
                    disabled={!canSend}
                    onClick={submit}
                    type="button"
                  >
                    <ArrowRight
                      className={cn(
                        "h-4 w-4 transition-opacity duration-200 dark:text-white",
                        canSend ? "opacity-100" : "opacity-30"
                      )}
                    />
                  </button>
                )}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
