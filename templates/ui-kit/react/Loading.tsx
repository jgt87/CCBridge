/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * Adapted from kokonutui ai-text-loading, with a soft pulse instead of the gradient
 * (MIT licence, see ../LICENSE-kokonutui.txt; https://kokonutui.com).
 */

/** Loading text with a spinner. */
export function Loading({ text = "Loading..." }: { text?: string }) {
  return (
    <span className="kit-loading" role="status">
      <span aria-hidden="true" className="kit-spinner" />
      <span className="kit-loading__text">{text}</span>
    </span>
  );
}
