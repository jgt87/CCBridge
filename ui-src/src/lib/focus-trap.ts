// Focus inside a modal layer (components/ccb/modal-backdrop.tsx, the side panel over the chat in
// app-layout.tsx): where focus starts, and Tab kept inside.

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
const FIELDS = 'input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled])';

const shown = (el: HTMLElement) => !el.closest("[hidden]") && el.getClientRects().length > 0;

/** The parts of a layer that take focus, in document order (hidden ones left out). */
export function focusableIn(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(shown);
}

/** Where focus goes when a modal opens: the first field inside, else the first control, else the layer itself. */
export function initialFocus(root: HTMLElement): HTMLElement {
  const field = Array.from(root.querySelectorAll<HTMLElement>(FIELDS)).find(shown);
  return field ?? focusableIn(root)[0] ?? root;
}

/**
 * Tab and Shift+Tab wrap inside the layer: the element to focus instead of leaving it, or null to let
 * the key do its usual move. An empty layer keeps focus on itself.
 */
export function wrapTarget(root: HTMLElement, active: Element | null, back: boolean): HTMLElement | null {
  const items = focusableIn(root);
  if (items.length === 0) return root;
  const first = items[0];
  const last = items[items.length - 1];
  if (back && (active === first || active === root)) return last;
  if (!back && active === last) return first;
  // Focus elsewhere (a menu opened from the layer lives in its own layer): its own keys apply.
  return null;
}

/** A keydown handler for the layer's element: Tab never leaves it. */
export function keepFocusInside(e: { key: string; shiftKey: boolean; currentTarget: HTMLElement; preventDefault: () => void }) {
  if (e.key !== "Tab") return;
  const target = wrapTarget(e.currentTarget, document.activeElement, e.shiftKey);
  if (!target) return;
  e.preventDefault();
  target.focus();
}
