/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { type ReactNode, useEffect, useId, useRef } from "react";

/** A side panel at the right edge (a sheet from the bottom on a phone) for the details of a row or an edit in place. */
export function Drawer({ open, onClose, title, children, actions }: { open: boolean; onClose: () => void; title: string; children: ReactNode; actions?: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) {
      if (d.showModal) d.showModal();
      else d.setAttribute("open", "");
    } else if (!open && d.open) {
      if (d.close) d.close();
      else d.removeAttribute("open");
    }
  }, [open]);
  return (
    <dialog
      aria-labelledby={titleId}
      className="kit-drawer"
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose(); // the backdrop
      }}
      ref={ref}
    >
      <div className="kit-drawer__head">
        <h3 className="kit-drawer__title" id={titleId}>
          {title}
        </h3>
        <button className="kit-btn kit-btn--ghost kit-btn--sm" onClick={onClose} type="button">
          Close
        </button>
      </div>
      <div className="kit-drawer__body">{children}</div>
      {actions ? <div className="kit-drawer__actions">{actions}</div> : null}
    </dialog>
  );
}
