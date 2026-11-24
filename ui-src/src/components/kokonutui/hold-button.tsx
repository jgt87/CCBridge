"use client";

/**
 * @author: @dorianbaffier
 * @description: Hold Button
 * @version: 1.0.0
 * @date: 2025-06-26
 * @license: MIT
 * @website: https://kokonutui.com
 */

import { cva, type VariantProps } from "class-variance-authority";
import {
  AlertCircleIcon,
  ArchiveXIcon,
  BanIcon,
  Trash2Icon,
  XCircleIcon,
} from "lucide-react";
import { motion, useAnimation } from "motion/react";
import { useId, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { type HoldVariant, holdCompleted, holdFillClass, holdIconVariant } from "@/lib/hold-button";
import { cn } from "@/lib/utils";

const holdButtonVariants = cva("relative min-w-40 touch-manipulation select-none overflow-hidden", {
  variants: {
    variant: {
      red: [
        "bg-red-100 dark:bg-red-200",
        "hover:bg-red-100 dark:hover:bg-red-200",
        "text-red-500 dark:text-red-600",
        "border border-red-200 dark:border-red-300",
      ],
      green: [
        "bg-green-100 dark:bg-green-200",
        "hover:bg-green-100 dark:hover:bg-green-200",
        "text-green-500 dark:text-green-600",
        "border border-green-200 dark:border-green-300",
      ],
      blue: [
        "bg-blue-100 dark:bg-blue-200",
        "hover:bg-blue-100 dark:hover:bg-blue-200",
        "text-blue-500 dark:text-blue-600",
        "border border-blue-200 dark:border-blue-300",
      ],
      orange: [
        "bg-orange-100 dark:bg-orange-200",
        "hover:bg-orange-100 dark:hover:bg-orange-200",
        "text-orange-500 dark:text-orange-600",
        "border border-orange-200 dark:border-orange-300",
      ],
      // StreamHub: flat grey (no border), like the other buttons.
      grey: [
        "bg-black/5 dark:bg-white/10",
        "hover:bg-black/10 dark:hover:bg-white/15",
        "text-foreground shadow-none",
      ],
    },
  },
  defaultVariants: {
    variant: "red",
  },
});

interface HoldButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof holdButtonVariants> {
  holdDuration?: number;
  /** StreamHub: text shown while idle / while holding, and the action fired once the hold completes. */
  label?: string;
  holdingLabel?: string;
  icon?: React.ReactNode;
  onHoldComplete?: () => void;
}

const isHoldKey = (k: string) => k === " " || k === "Enter";

const VARIANT_ICON: Record<HoldVariant, typeof Trash2Icon> = {
  red: Trash2Icon,
  green: ArchiveXIcon,
  blue: XCircleIcon,
  orange: AlertCircleIcon,
  grey: BanIcon,
};

// StreamHub: the hold itself: the fill animation, and onHoldComplete once it was held the whole time.
function useHold(holdDuration: number, disabled: boolean | undefined, onHoldComplete?: () => void) {
  const [isHolding, setIsHolding] = useState(false);
  const holdingRef = useRef(false);
  const controls = useAnimation();

  const [done, setDone] = useState(false);

  async function handleHoldStart() {
    // StreamHub: one hold at a time (a held key repeats; a second pointer does not restart it).
    if (disabled || holdingRef.current) return;
    setDone(false);
    setIsHolding(true);
    holdingRef.current = true;
    const started = Date.now();
    controls.set({ width: "0%" });
    await controls.start({
      width: "100%",
      transition: {
        duration: holdDuration / 1000,
        ease: "linear",
      },
    });
    // The promise also resolves when the hold is released early, so check both.
    if (holdCompleted(holdingRef.current, started, Date.now(), holdDuration)) {
      holdingRef.current = false;
      setIsHolding(false);
      setDone(true);
      onHoldComplete?.();
    }
  }

  function handleHoldEnd() {
    holdingRef.current = false;
    setIsHolding(false);
    controls.stop();
    controls.start({
      width: "0%",
      transition: { duration: 0.1 },
    });
  }

  return { isHolding, done, controls, handleHoldStart, handleHoldEnd };
}

export default function HoldButton({
  className,
  variant = "red",
  holdDuration = 3000,
  label = "Hold me",
  holdingLabel = "Release",
  icon,
  onHoldComplete,
  ...props
}: HoldButtonProps) {
  const { isHolding, done, controls, handleHoldStart, handleHoldEnd } = useHold(holdDuration, props.disabled, onHoldComplete);
  const Icon = VARIANT_ICON[holdIconVariant(variant)];
  const helpId = useId();

  return (
    <>
    <Button
      aria-describedby={helpId}
      className={cn(holdButtonVariants({ variant, className }))}
      onBlur={handleHoldEnd}
      // StreamHub: the hold is the action, never a click (Space and Enter would click on their own).
      onClick={(e) => e.preventDefault()}
      onKeyDown={(e) => {
        // Space and Enter hold too, as with the kit's hold button; a held key repeats and does not restart it.
        if (!isHoldKey(e.key)) return;
        e.preventDefault();
        if (!e.repeat) void handleHoldStart();
      }}
      onKeyUp={(e) => {
        if (isHoldKey(e.key)) e.preventDefault();
        handleHoldEnd();
      }}
      onPointerCancel={handleHoldEnd}
      onPointerDown={(e) => {
        // Only the main button holds (not a right or middle press).
        if (e.button === 0) void handleHoldStart();
      }}
      onPointerLeave={handleHoldEnd}
      onPointerUp={handleHoldEnd}
      {...props}
    >
      <motion.div
        animate={controls}
        className={cn("absolute top-0 left-0 h-full", holdFillClass(variant))}
        initial={{ width: "0%" }}
      />
      <span className="relative z-10 flex w-full items-center justify-center gap-2">
        {icon ?? (Icon && <Icon className="h-4 w-4" />)}
        {isHolding ? holdingLabel : label}
      </span>
    </Button>
    {/* Beside the button, so its name stays its label: the hold described, and announced when done. */}
    <span hidden id={helpId}>
      Press and hold to confirm
    </span>
    <span aria-live="polite" className="sr-only">
      {done ? `${label}: confirmed` : ""}
    </span>
    </>
  );
}
