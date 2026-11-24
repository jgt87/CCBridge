import type React from "react";
import { Children, cloneElement, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { initialFocus, keepFocusInside } from "@/lib/focus-trap";
import { cn } from "@/lib/utils";

/** The look every modal shares (menu, settings, schedules, file viewer): the app behind is dimmed and blurred. */
export const BACKDROP = "bg-(--kit-backdrop) backdrop-blur-sm";

/** Makes everything on the page beside the modal inert; returns the undo (only for the elements it changed). */
function makeRestInert(modal: HTMLElement): () => void {
  const changed: HTMLElement[] = [];
  for (const el of Array.from(document.body.children)) {
    if (el === modal || !(el instanceof HTMLElement) || el.inert) continue;
    el.inert = true;
    changed.push(el);
  }
  return () => {
    for (const el of changed) el.inert = false;
  };
}

/**
 * Full-screen backdrop for a modal dialog; a press on it (outside the content) closes the modal.
 * Its one child, the panel, is the dialog for assistive technology: role dialog, aria-modal and a
 * name (its visible title through aria-labelledby, else the label). Focus moves in on open and stays
 * inside (Tab wraps), the page behind is inert (the backdrop is portalled to the body), and focus goes
 * back to where it was on close, without scrolling.
 */
export function ModalBackdrop({
  onClose,
  label,
  titleId,
  center = false,
  className,
  children,
}: {
  onClose: () => void;
  /** The dialog's name for screen readers ("Settings", "Scheduled", the file's path), when it has no titleId. */
  label: string;
  /** The id of the dialog's visible title: the dialog is then named by it (aria-labelledby), not by label. */
  titleId?: string;
  /** Centre the content (file viewer) instead of placing it near the top (menus, panels). */
  center?: boolean;
  className?: string;
  /** The panel: one element (a div.kit-dialog), which gets the dialog's role, label and keys. */
  children: React.ReactElement<React.HTMLAttributes<HTMLElement> & { ref?: React.Ref<HTMLElement> }>;
}) {
  const backdrop = useRef<HTMLDivElement>(null);
  const panel = useRef<HTMLElement>(null);
  // Read while rendering, before a field inside takes focus with autoFocus.
  const [opener] = useState(() => (document.activeElement instanceof HTMLElement ? document.activeElement : null));
  useEffect(() => {
    const layer = backdrop.current;
    const dialog = panel.current;
    if (!layer || !dialog) return;
    const restore = makeRestInert(layer);
    // A field that focused itself (autoFocus) keeps it; otherwise the first field or control.
    if (!dialog.contains(document.activeElement)) initialFocus(dialog).focus({ preventScroll: true });
    return () => {
      restore();
      if (opener?.isConnected) opener.focus({ preventScroll: true });
    };
  }, [opener]);

  const child = Children.only(children);
  const dialog = cloneElement(child, {
    ...(titleId ? { "aria-labelledby": titleId } : { "aria-label": label }),
    "aria-modal": true,
    onKeyDown: (e: React.KeyboardEvent<HTMLElement>) => {
      child.props.onKeyDown?.(e);
      keepFocusInside(e);
    },
    ref: panel,
    role: "dialog",
    tabIndex: -1,
  });
  return createPortal(
    <div
      className={cn("fixed inset-0 z-50 flex justify-center", BACKDROP, center ? "items-center p-6" : "items-start px-4 pt-16", className)}
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
      ref={backdrop}
    >
      {dialog}
    </div>,
    document.body
  );
}
