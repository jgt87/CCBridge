"use client";

/**
 * @author: @kokonutui
 * @description: A modern search bar component with action buttons and suggestions
 * @version: 1.0.0
 * @date: 2025-06-26
 * @license: MIT
 * @website: https://kokonutui.com
 * @github: https://github.com/kokonut-labs/kokonutui
 */

import { Search, Send } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Input } from "@/components/ui/input";
import useDebounce from "@/hooks/use-debounce";

export interface Action {
  id: string;
  label: string;
  icon: React.ReactNode;
  description?: string;
  short?: string;
  end?: string;
  /** CCBridge: runs when the action is chosen. */
  onSelect?: () => void;
}

interface SearchResult {
  actions: Action[];
}
const ANIMATION_VARIANTS = {
  container: {
    hidden: { opacity: 0, height: 0 },
    show: {
      opacity: 1,
      height: "auto",
      transition: {
        height: { duration: 0.4 },
        staggerChildren: 0.1,
      },
    },
    exit: {
      opacity: 0,
      height: 0,
      transition: {
        height: { duration: 0.3 },
        opacity: { duration: 0.2 },
      },
    },
  },
  item: {
    hidden: { opacity: 0, y: 20 },
    show: {
      opacity: 1,
      y: 0,
      transition: { duration: 0.3 },
    },
    exit: {
      opacity: 0,
      y: -10,
      transition: { duration: 0.2 },
    },
  },
} as const;

/**
 * CCBridge: used as the Ctrl+K command palette in a modal. It opens focused, filters on
 * label + description, runs action.onSelect on Enter/click and calls onClose afterwards.
 */
function ActionSearchBar({
  actions,
  label = "Search Commands",
  placeholder = "Type a command or file name...",
  onClose,
  maxResults = 12,
}: {
  actions: Action[];
  label?: string;
  placeholder?: string;
  onClose?: () => void;
  maxResults?: number;
}) {
  const [query, setQuery] = useState("");
  const [activeIndex, setActiveIndex] = useState(0);
  const debouncedQuery = useDebounce(query, 120);

  const filteredActions = useMemo(() => {
    const q = debouncedQuery.toLowerCase().trim();
    const list = q
      ? actions.filter((action) =>
          `${action.label} ${action.description || ""}`.toLowerCase().includes(q)
        )
      : actions;
    return list.slice(0, maxResults);
  }, [debouncedQuery, actions, maxResults]);

  const result: SearchResult = { actions: filteredActions };

  useEffect(() => {
    setActiveIndex(0);
  }, [debouncedQuery]);

  const choose = useCallback(
    (action: Action | undefined) => {
      if (!action) return;
      action.onSelect?.();
      onClose?.();
    },
    [onClose]
  );

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => setQuery(e.target.value),
    []
  );

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLInputElement>) => {
      switch (e.key) {
        case "ArrowDown":
          e.preventDefault();
          setActiveIndex((prev) => (prev < result.actions.length - 1 ? prev + 1 : 0));
          break;
        case "ArrowUp":
          e.preventDefault();
          setActiveIndex((prev) => (prev > 0 ? prev - 1 : result.actions.length - 1));
          break;
        case "Enter":
          e.preventDefault();
          choose(result.actions[activeIndex]);
          break;
        case "Escape":
          onClose?.();
          break;
      }
    },
    [result.actions, activeIndex, choose, onClose]
  );

  return (
    <div className="mx-auto w-full max-w-xl">
      <div className="relative flex flex-col items-center justify-start">
        <div className="w-full pt-4 pb-1">
          <label
            className="mb-1 block font-medium text-gray-500 text-xs dark:text-gray-400"
            htmlFor="search"
          >
            {label}
          </label>
          <div className="relative">
            <Input
              aria-activedescendant={
                activeIndex >= 0 ? `action-${result.actions[activeIndex]?.id}` : undefined
              }
              aria-autocomplete="list"
              aria-expanded
              autoComplete="off"
              autoFocus
              className="h-9 rounded-lg py-1.5 pr-9 pl-3 text-sm focus-visible:ring-offset-0"
              id="search"
              onChange={handleInputChange}
              onKeyDown={handleKeyDown}
              placeholder={placeholder}
              role="combobox"
              type="text"
              value={query}
            />
            <div className="absolute top-1/2 right-3 h-4 w-4 -translate-y-1/2">
              <AnimatePresence mode="popLayout">
                {query.length > 0 ? (
                  <motion.div
                    animate={{ y: 0, opacity: 1 }}
                    exit={{ y: 20, opacity: 0 }}
                    initial={{ y: -20, opacity: 0 }}
                    key="send"
                    transition={{ duration: 0.2 }}
                  >
                    <Send className="h-4 w-4 text-gray-400 dark:text-gray-500" />
                  </motion.div>
                ) : (
                  <motion.div
                    animate={{ y: 0, opacity: 1 }}
                    exit={{ y: 20, opacity: 0 }}
                    initial={{ y: -20, opacity: 0 }}
                    key="search"
                    transition={{ duration: 0.2 }}
                  >
                    <Search className="h-4 w-4 text-gray-400 dark:text-gray-500" />
                  </motion.div>
                )}
              </AnimatePresence>
            </div>
          </div>
        </div>

        <div className="w-full">
          <AnimatePresence>
            <motion.div
              animate="show"
              aria-label="Search results"
              className="mt-1 w-full overflow-hidden rounded-md border bg-white shadow-xs dark:border-gray-800 dark:bg-black"
              exit="exit"
              initial="hidden"
              role="listbox"
              variants={ANIMATION_VARIANTS.container}
            >
              <motion.ul role="none">
                {result.actions.length === 0 && (
                  <li className="px-3 py-2 text-gray-400 text-sm">No matches</li>
                )}
                {result.actions.map((action, index) => (
                  <motion.li
                    aria-selected={activeIndex === index}
                    className={`flex cursor-pointer items-center justify-between rounded-md px-3 py-2 hover:bg-gray-200 dark:hover:bg-zinc-900 ${
                      activeIndex === index ? "bg-gray-100 dark:bg-zinc-800" : ""
                    }`}
                    id={`action-${action.id}`}
                    key={action.id}
                    layout
                    onClick={() => choose(action)}
                    onMouseEnter={() => setActiveIndex(index)}
                    role="option"
                    variants={ANIMATION_VARIANTS.item}
                  >
                    <div className="flex min-w-0 items-center justify-between gap-2">
                      <div className="flex min-w-0 items-center gap-2">
                        <span aria-hidden="true" className="text-gray-500">
                          {action.icon}
                        </span>
                        <span className="truncate font-medium text-gray-900 text-sm dark:text-gray-100">
                          {action.label}
                        </span>
                        {action.description && (
                          <span className="truncate text-gray-400 text-xs">
                            {action.description}
                          </span>
                        )}
                      </div>
                    </div>
                    <div className="flex shrink-0 items-center gap-2">
                      {action.short && (
                        <span
                          aria-label={`Keyboard shortcut: ${action.short}`}
                          className="text-gray-400 text-xs"
                        >
                          {action.short}
                        </span>
                      )}
                      {action.end && (
                        <span className="text-right text-gray-400 text-xs">{action.end}</span>
                      )}
                    </div>
                  </motion.li>
                ))}
              </motion.ul>
              <div className="mt-2 border-gray-100 border-t px-3 py-2 dark:border-gray-800">
                <div className="flex items-center justify-between text-gray-500 text-xs">
                  <span>Enter to choose</span>
                  <span>ESC to cancel</span>
                </div>
              </div>
            </motion.div>
          </AnimatePresence>
        </div>
      </div>
    </div>
  );
}

export default ActionSearchBar;