"use client";

/**
 * @author: @dorianbaffier
 * @description: Smooth Tab
 * @version: 1.0.0
 * @date: 2025-06-26
 * @license: MIT
 * @website: https://kokonutui.com
 */

import type { LucideIcon } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import * as React from "react";
import { cn } from "@/lib/utils";

export interface TabItem {
  id: string;
  title: string;
  description?: string;
  icon?: LucideIcon;
  /** Shown after the title, for example a Beta tag. */
  badge?: React.ReactNode;
  content?: React.ReactNode;
  cardContent?: React.ReactNode;
  color: string;
}

const WaveformPath = () => (
  <motion.path
    animate={{
      x: [0, 10, 0],
      transition: {
        duration: 5,
        ease: "linear",
        repeat: Number.POSITIVE_INFINITY,
      },
    }}
    d="M0 50 
           C 20 40, 40 30, 60 50
           C 80 70, 100 60, 120 50
           C 140 40, 160 30, 180 50
           C 200 70, 220 60, 240 50
           C 260 40, 280 30, 300 50
           C 320 70, 340 60, 360 50
           C 380 40, 400 30, 420 50
           L 420 100 L 0 100 Z"
    initial={false}
  />
);

function TabCardContent({
  title,
  description,
  fillClass,
}: {
  title: string;
  description: string;
  fillClass: string;
}) {
  return (
    <div className="relative h-full">
      <div className="absolute inset-0 overflow-hidden">
        <svg
          aria-hidden="true"
          className="absolute bottom-0 h-32 w-full"
          preserveAspectRatio="none"
          role="presentation"
          viewBox="0 0 420 100"
        >
          <motion.g
            animate={{ opacity: 0.15 }}
            className={`fill-${fillClass} stroke-${fillClass}`}
            initial={{ opacity: 0 }}
            style={{ strokeWidth: 1 }}
            transition={{ duration: 0.5 }}
          >
            <WaveformPath />
          </motion.g>
          <motion.g
            animate={{ opacity: 0.1 }}
            className={`fill-${fillClass} stroke-${fillClass}`}
            initial={{ opacity: 0 }}
            style={{ strokeWidth: 1, transform: "translateY(10px)" }}
            transition={{ duration: 0.5 }}
          >
            <WaveformPath />
          </motion.g>
        </svg>
      </div>
      <div className="relative flex h-full flex-col p-6">
        <div className="space-y-2">
          <h3 className="bg-gradient-to-r from-foreground via-foreground/90 to-foreground/70 font-semibold text-2xl tracking-tight [text-shadow:_0_1px_1px_rgb(0_0_0_/_10%)]">
            {title}
          </h3>
          <p className="max-w-[90%] text-black/50 text-sm leading-relaxed dark:text-white/65">
            {description}
          </p>
        </div>
      </div>
    </div>
  );
}

const DEFAULT_TABS: TabItem[] = [
  {
    id: "Models",
    title: "Models",
    description: "Choose the model you want to use",
    color: "bg-blue-500 hover:bg-blue-600",
  },
  {
    id: "MCPs",
    title: "MCPs",
    description: "Choose the MCP you want to use",
    color: "bg-purple-500 hover:bg-purple-600",
  },
  {
    id: "Agents",
    title: "Agents",
    description: "Choose the agent you want to use",
    color: "bg-emerald-500 hover:bg-emerald-600",
  },
  {
    id: "Users",
    title: "Users",
    description: "Choose the user you want to use",
    color: "bg-amber-500 hover:bg-amber-600",
  },
];

interface SmoothTabProps {
  items?: TabItem[];
  defaultTabId?: string;
  className?: string;
  activeColor?: string;
  onChange?: (tabId: string) => void;
  /** CCBridge: switch to a tab from outside; a new `n` switches again (also to the same tab). */
  request?: { id: string; n: number } | null;
}

const slideVariants = {
  enter: (direction: number) => ({
    x: direction > 0 ? "100%" : "-100%",
    opacity: 0,
    filter: "blur(8px)",
    scale: 0.95,
    position: "absolute" as const,
  }),
  center: {
    x: 0,
    opacity: 1,
    filter: "blur(0px)",
    scale: 1,
    position: "absolute" as const,
  },
  exit: (direction: number) => ({
    x: direction < 0 ? "100%" : "-100%",
    opacity: 0,
    filter: "blur(8px)",
    scale: 0.95,
    position: "absolute" as const,
  }),
};

const transition = {
  duration: 0.4,
  ease: [0.32, 0.72, 0, 1],
};

export default function SmoothTab({
  items = DEFAULT_TABS,
  defaultTabId = DEFAULT_TABS[0].id,
  className,
  activeColor = "bg-[#1F9CFE]",
  onChange,
  columns,
  request,
}: SmoothTabProps & { columns?: number }) {
  const [selected, setSelected] = React.useState<string>(defaultTabId);
  const [direction, setDirection] = React.useState(0);
  const [dimensions, setDimensions] = React.useState({ width: 0, height: 0, left: 0, top: 0 });
  // CCBridge: the first placement (page load) is instant and the highlight stays hidden until the
  // selected tab is measured, so a refresh shows the tab already selected instead of sliding in.
  const [placed, setPlaced] = React.useState(false);
  // CCBridge: tabs can wrap into a grid (e.g. 2 x 2), so the highlight follows both axes.
  const cols = Math.max(1, Math.min(columns ?? items.length, items.length));

  // Reference for the selected button
  const buttonRefs = React.useRef<Map<string, HTMLButtonElement>>(new Map());
  const containerRef = React.useRef<HTMLDivElement>(null);

  // Update dimensions whenever selected tab changes or on mount
  React.useLayoutEffect(() => {
    const updateDimensions = () => {
      const selectedButton = buttonRefs.current.get(selected);
      const container = containerRef.current;

      if (selectedButton && container) {
        const rect = selectedButton.getBoundingClientRect();
        const containerRect = container.getBoundingClientRect();

        setDimensions({
          width: rect.width,
          height: rect.height,
          left: rect.left - containerRect.left,
          top: rect.top - containerRect.top,
        });
        if (rect.width > 0 && !placed) requestAnimationFrame(() => setPlaced(true));
      }
    };

    // Initial update: measure now (layout is ready in a layout effect) and once more after paint
    updateDimensions();
    requestAnimationFrame(() => {
      updateDimensions();
    });

    // Update on resize, also of the tab bar itself (side panel opened, closed or resized)
    window.addEventListener("resize", updateDimensions);
    const ro = typeof ResizeObserver !== "undefined" && containerRef.current ? new ResizeObserver(updateDimensions) : null;
    if (ro && containerRef.current) ro.observe(containerRef.current);
    return () => {
      window.removeEventListener("resize", updateDimensions);
      ro?.disconnect();
    };
  }, [selected]);

  const handleTabClick = (tabId: string) => {
    const currentIndex = items.findIndex((item) => item.id === selected);
    const newIndex = items.findIndex((item) => item.id === tabId);
    setDirection(newIndex > currentIndex ? 1 : -1);
    setSelected(tabId);
    onChange?.(tabId);
  };

  // biome-ignore lint/correctness/useExhaustiveDependencies: only a new request switches the tab
  React.useEffect(() => {
    if (request && request.id !== selected && items.some((i) => i.id === request.id)) handleTabClick(request.id);
  }, [request?.n]);

  const handleKeyDown = (
    e: React.KeyboardEvent<HTMLButtonElement>,
    tabId: string
  ) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      handleTabClick(tabId);
    }
  };

  const selectedItem = items.find((item) => item.id === selected);

  // CCBridge: tab bar on top, panel fills the remaining height and scrolls; the
  // panel shows item.content (the decorative card stays as the fallback).
  return (
    <div className="flex h-full min-h-0 flex-col">
      <div
        aria-label="Smooth tabs"
        className={cn(
          "relative flex items-center justify-between gap-1 p-1",
          "w-full bg-background",
          "rounded-xl border",
          "transition-all duration-200",
          className
        )}
        ref={containerRef}
        role="tablist"
      >
        {/* Sliding Background */}
        <motion.div
          animate={{
            width: dimensions.width,
            height: dimensions.height,
            x: dimensions.left,
            y: dimensions.top,
            opacity: dimensions.width > 0 ? 1 : 0,
          }}
          className={cn(
            "absolute top-0 left-0 z-[1] rounded-lg",
            selectedItem?.color || activeColor
          )}
          initial={false}
          transition={placed ? { type: "spring", stiffness: 400, damping: 30 } : { duration: 0 }}
        />

        <div
          className="relative z-[2] grid w-full gap-1"
          style={{ gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))` }}
        >
          {items.map((item, index) => {
            const isSelected = selected === item.id;
            // The last tab spans the columns its row leaves free (room for a badge).
            const spare = index === items.length - 1 ? (cols - (items.length % cols)) % cols : 0;
            const Icon = item.icon;
            return (
              <motion.button
                aria-controls={`panel-${item.id}`}
                aria-selected={isSelected}
                className={cn(
                  "relative flex items-center justify-center gap-1 rounded-lg px-1 py-1.5",
                  "font-medium text-sm transition-all duration-300",
                  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                  "truncate",
                  isSelected
                    ? "text-white"
                    : "text-muted-foreground hover:bg-muted/50 hover:text-foreground"
                )}
                id={`tab-${item.id}`}
                key={item.id}
                onClick={() => handleTabClick(item.id)}
                onKeyDown={(e) => handleKeyDown(e, item.id)}
                ref={(el) => {
                  if (el) buttonRefs.current.set(item.id, el);
                  else buttonRefs.current.delete(item.id);
                }}
                role="tab"
                style={spare ? { gridColumn: `span ${spare + 1} / span ${spare + 1}` } : undefined}
                tabIndex={isSelected ? 0 : -1}
                type="button"
              >
                {Icon && <Icon className="h-3.5 w-3.5 shrink-0" />}
                <span className="truncate">{item.title}</span>
                {item.badge && <span className="shrink-0">{item.badge}</span>}
              </motion.button>
            );
          })}
        </div>
      </div>

      <div className="relative mt-3 min-h-0 flex-1">
        <div className="absolute inset-0 overflow-hidden rounded-lg border bg-card">
          <AnimatePresence custom={direction} initial={false} mode="popLayout">
            <motion.div
              animate="center"
              className="absolute inset-0 h-full w-full overflow-y-auto bg-card will-change-transform"
              custom={direction}
              exit="exit"
              id={`panel-${selected}`}
              initial="enter"
              key={`card-${selected}`}
              role="tabpanel"
              style={{
                backfaceVisibility: "hidden",
                WebkitBackfaceVisibility: "hidden",
              }}
              transition={transition as any}
              variants={slideVariants as any}
            >
              {selectedItem?.content ??
                selectedItem?.cardContent ??
                (selectedItem && (
                  <TabCardContent
                    description={selectedItem.description ?? ""}
                    fillClass={
                      selectedItem.color
                        .split(" ")
                        .at(0)
                        ?.replace("bg-", "") ?? "blue-500"
                    }
                    title={selectedItem.title}
                  />
                ))}
            </motion.div>
          </AnimatePresence>
        </div>
      </div>
    </div>
  );
}