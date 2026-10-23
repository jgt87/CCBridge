// The rules of the hold-to-confirm button (components/kokonutui/hold-button.tsx).

export type HoldVariant = "red" | "green" | "blue" | "orange" | "grey";

const FILL: Record<HoldVariant, string> = {
  red: "bg-red-200/30 dark:bg-red-300/30",
  green: "bg-green-200/30 dark:bg-green-300/30",
  blue: "bg-blue-200/30 dark:bg-blue-300/30",
  orange: "bg-orange-200/30 dark:bg-orange-300/30",
  grey: "bg-black/10 dark:bg-white/15",
};

/** The colour of the bar that fills while held; none for an unknown or missing variant. */
export const holdFillClass = (variant: HoldVariant | null | undefined) => (variant ? FILL[variant] ?? "" : "");

/** The variant whose icon shows: a missing variant shows the red one's. */
export const holdIconVariant = (variant: HoldVariant | null | undefined): HoldVariant => variant || "red";

/** The hold finished: still held, and held for the whole time (the animation also ends on an early release). */
export const holdCompleted = (holding: boolean, started: number, now: number, holdDuration: number) =>
  holding && now - started >= holdDuration - 50;
