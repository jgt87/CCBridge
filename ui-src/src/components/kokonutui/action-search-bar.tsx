"use client";

/**
 * @author: @kokonutui
 * @description: A modern search bar component with action buttons and suggestions
 * @version: 1.0.0
 * @date: 2025-06-26
 * @license: MIT
 * @website: https://kokonutui.com
 */

import { Search, Send } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Input } from "@/components/ui/input";
import useDebounce from "@/hooks/use-debounce";
import { actionTitle, filterActions, nextIndex, prevIndex } from "@/lib/action-search";

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
      // CCBridge: quick, so the whole list is there in about a quarter of a second.
      transition: {
        height: { duration: 0.15 },
        staggerChildren: 0.015,
      },
    },
    exit: {
      opacity: 0,
      height: 0,
      transition: {
        height: { duration: 0.12 },
        opacity: { duration: 0.1 },
      },
    },
  },
  item: {
    hidden: { opacity: 0, y: 6 },
    show: {
      opacity: 1,
      y: 0,
      transition: { duration: 0.12 },
    },
    exit: {
      opacity: 0,
      y: -4,
      transition: { duration: 0.08 },
    },
  },
} as const;

// CCBridge: the query, the matching actions, the highlighted row and the keys, apart from the markup.
function useActionSearch(actions: Action[], maxResults: number, onClose?: () => void) {
  const [query, setQuery] = useState("");
  const [activeIndex, setActiveIndex] = useState(0);
  const debouncedQuery = useDebounce(query, 120);

  const filteredActions = useMemo(
    () => filterActions(actions, debouncedQuery, maxResults),
    [debouncedQuery, actions, maxResults]
  );

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
          setActiveIndex((prev) => nextIndex(prev, result.actions.length));
          break;
        case "ArrowUp":
          e.preventDefault();
          setActiveIndex((prev) => prevIndex(prev, result.actions.length));
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

  return { query, result, activeIndex, setActiveIndex, choose, handleInputChange, handleKeyDown };
}

// The icon at the end of the field: Send once something is typed, else Search.
const QueryIcon = ({ typed }: { typed: boolean }) => (
  <div className="absolute top-1/2 right-3 h-4 w-4 -translate-y-1/2">
    <AnimatePresence mode="popLayout">
      {typed ? (
        <motion.div
          animate={{ y: 0, opacity: 1 }}
          exit={{ y: 20, opacity: 0 }}
          initial={{ y: -20, opacity: 0 }}
          key="send"
          transition={{ duration: 0.2 }}
        >
          <Send className="h-4 w-4 text-muted-foreground" />
        </motion.div>
      ) : (
        <motion.div
          animate={{ y: 0, opacity: 1 }}
          exit={{ y: 20, opacity: 0 }}
          initial={{ y: -20, opacity: 0 }}
          key="search"
          transition={{ duration: 0.2 }}
        >
          <Search className="h-4 w-4 text-muted-foreground" />
        </motion.div>
      )}
    </AnimatePresence>
  </div>
);

// One action in the list: icon, label, description, and its shortcut and end text.
const ActionRow = ({
  action,
  active,
  onChoose,
  onHover,
}: {
  action: Action;
  active: boolean;
  onChoose: () => void;
  onHover: () => void;
}) => (
  <motion.li
    aria-selected={active}
    className={`flex cursor-pointer items-center justify-between gap-3 rounded-md px-3 py-2 hover:bg-gray-200 dark:hover:bg-white/5 ${
      active ? "bg-black/5 dark:bg-white/10" : ""
    }`}
    id={`action-${action.id}`}
    layout
    onClick={onChoose}
    onMouseEnter={onHover}
    role="option"
    // The whole text on hover when the description is cut off.
    title={actionTitle(action)}
    variants={ANIMATION_VARIANTS.item}
  >
    <div className="flex min-w-0 flex-1 items-center gap-2">
      <div className="flex min-w-0 flex-1 items-center gap-2">
        <span aria-hidden="true" className="shrink-0 text-muted-foreground">
          {action.icon}
        </span>
        {/* The item first: it keeps its width (up to most of the row); the description gives way. */}
        <span className="max-w-[70%] shrink-0 truncate font-medium text-foreground text-sm">
          {action.label}
        </span>
        {action.description && (
          <span className="min-w-0 flex-1 truncate text-muted-foreground text-xs">
            {action.description}
          </span>
        )}
      </div>
    </div>
    <div className="flex shrink-0 items-center gap-2">
      {action.short && (
        <span
          aria-label={`Keyboard shortcut: ${action.short}`}
          className="text-muted-foreground text-xs"
        >
          {action.short}
        </span>
      )}
      {action.end && (
        <span className="text-right text-muted-foreground text-xs">{action.end}</span>
      )}
    </div>
  </motion.li>
);

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
  const { query, result, activeIndex, setActiveIndex, choose, handleInputChange, handleKeyDown } =
    useActionSearch(actions, maxResults, onClose);

  return (
    <div className="mx-auto w-full max-w-xl">
      <div className="relative flex flex-col items-center justify-start">
        <div className="w-full pt-4 pb-1">
          <label
            className="mb-1 block font-medium text-muted-foreground text-xs"
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
            <QueryIcon typed={query.length > 0} />
          </div>
        </div>

        <div className="w-full">
          <AnimatePresence>
            <motion.div
              animate="show"
              aria-label="Search results"
              className="mt-1 w-full overflow-hidden rounded-md border bg-white shadow-xs dark:border-white/10 dark:bg-popover"
              exit="exit"
              initial="hidden"
              role="listbox"
              variants={ANIMATION_VARIANTS.container}
            >
              <motion.ul role="none">
                {result.actions.length === 0 && (
                  <li className="px-3 py-2 text-muted-foreground text-sm">No matches</li>
                )}
                {result.actions.map((action, index) => (
                  <ActionRow
                    action={action}
                    active={activeIndex === index}
                    key={action.id}
                    onChoose={() => choose(action)}
                    onHover={() => setActiveIndex(index)}
                  />
                ))}
              </motion.ul>
              <div className="mt-2 border-black/10 border-t px-3 py-2 dark:border-white/10">
                <div className="flex items-center justify-between text-muted-foreground text-xs">
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