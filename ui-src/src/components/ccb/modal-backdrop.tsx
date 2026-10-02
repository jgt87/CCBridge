import type React from "react";
import { cn } from "@/lib/utils";

/** The look every modal shares (menu, settings, schedules, file viewer): the app behind is dimmed and blurred. */
export const BACKDROP = "bg-black/40 backdrop-blur-sm";

/** Full-screen backdrop for a modal; a click on it (outside the content) closes the modal. */
export function ModalBackdrop({
  onClose,
  center = false,
  className,
  children,
}: {
  onClose: () => void;
  /** Centre the content (file viewer) instead of placing it near the top (menus, panels). */
  center?: boolean;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div
      className={cn("fixed inset-0 z-50 flex justify-center", BACKDROP, center ? "items-center p-6" : "items-start px-4 pt-16", className)}
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      {children}
    </div>
  );
}
