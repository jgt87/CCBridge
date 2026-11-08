/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { type ReactNode, useCallback, useEffect, useId, useRef, useState } from "react";

interface Box {
  text: ReactNode;
  title?: ReactNode;
  ok?: string;
  cancel?: string;
  danger?: boolean;
  alert?: boolean;
  resolve: (yes: boolean) => void;
}

/**
 * A kit dialog instead of the browser's own confirm() and alert():
 *   const { confirm, alert, box } = useConfirm();  ...  {box}
 *   if (await confirm("Delete 3 items?", { title: "Delete items", ok: "Delete", danger: true })) ...
 *   await alert("The export is ready.", { title: "Export" });
 */
export function useConfirm() {
  const [current, setCurrent] = useState<Box | null>(null);
  const queue = useRef<Box[]>([]);
  const next = useCallback(() => setCurrent(queue.current.shift() ?? null), []);
  const push = useCallback(
    (b: Omit<Box, "resolve">) =>
      new Promise<boolean>((resolve) => {
        queue.current.push({ ...b, resolve });
        setCurrent((c) => c ?? queue.current.shift() ?? null);
      }),
    [],
  );
  const confirm = useCallback((text: ReactNode, opts: { title?: ReactNode; ok?: string; cancel?: string; danger?: boolean } = {}) => push({ text, ...opts }), [push]);
  const alert = useCallback((text: ReactNode, opts: { title?: ReactNode; ok?: string } = {}) => push({ text, ...opts, alert: true }).then(() => undefined), [push]);
  const finish = (yes: boolean) => {
    current?.resolve(yes);
    next();
  };
  const box = current ? <ConfirmDialog box={current} onDone={finish} /> : null;
  return { confirm, alert, box };
}

function ConfirmDialog({ box, onDone }: { box: Box; onDone: (yes: boolean) => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const textId = useId();
  useEffect(() => {
    const d = ref.current;
    if (!d || d.open) return;
    if (d.showModal) d.showModal();
    else d.setAttribute("open", "");
    // A dangerous answer is never the default: with danger, Cancel has the focus (Enter does not delete).
    d.querySelector<HTMLButtonElement>(box.danger ? "[data-cancel]" : ".kit-btn--primary")?.focus();
  }, [box]);
  return (
    <dialog
      aria-describedby={textId}
      aria-labelledby={box.title ? titleId : textId}
      className="kit-dialog"
      onCancel={(e) => {
        e.preventDefault();
        onDone(false);
      }}
      ref={ref}
      role="alertdialog"
    >
      {box.title ? (
        <h3 className="kit-h3" id={titleId}>
          {box.title}
        </h3>
      ) : null}
      <p id={textId}>{box.text}</p>
      <div className="kit-dialog__actions">
        {box.alert ? null : (
          <button className="kit-btn" data-cancel onClick={() => onDone(false)} type="button">
            {box.cancel ?? "Cancel"}
          </button>
        )}
        <button className={"kit-btn " + (box.danger ? "kit-btn--danger" : "kit-btn--primary")} onClick={() => onDone(true)} type="button">
          {box.ok ?? "OK"}
        </button>
      </div>
    </dialog>
  );
}
