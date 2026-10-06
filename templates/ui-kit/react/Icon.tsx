/**
 * UI kit icon for React projects: a Lucide icon (ISC licence, see ../LICENSE-lucide.txt) from
 * ../kit-icons.js, which the helper program keeps filled with every icon name the project uses.
 * Needs only React.
 */
import "../kit-icons.js";

declare global {
  interface Window {
    KitIcons: { svg: (name: string, label?: string) => string };
  }
}

/** One icon in the current text colour. With label it is an image with that name; else decorative. */
export function Icon({ name, label, className }: { name: string; label?: string; className?: string }) {
  return (
    <span
      aria-hidden={label ? undefined : true}
      aria-label={label}
      className={className}
      dangerouslySetInnerHTML={{ __html: window.KitIcons.svg(name) }}
      role={label ? "img" : undefined}
      style={{ display: "inline-flex", lineHeight: 0 }}
    />
  );
}
