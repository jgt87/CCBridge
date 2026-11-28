/**
 * UI kit icon for React projects: a Lucide icon (ISC licence, see ../LICENSE-lucide.txt) from
 * ../kit-icons.js, which the kit tools keep filled with every icon name the project uses.
 * Needs only React.
 */
import "../kit-icons.js";

declare global {
  interface Window {
    KitIcons: { svg: (name: string, label?: string) => string };
  }
}

const warned = new Set<string>();

/** One icon in the current text colour. With label it is an image with that name; else decorative.
 *  An unknown name draws nothing and warns once, as the data-kit-icon path does. */
export function Icon({ name, label, className }: { name: string; label?: string; className?: string }) {
  const markup = window.KitIcons.svg(name);
  if (!markup && name && !warned.has(name)) {
    warned.add(name);
    console.warn("Unknown icon: " + name + " (kit-icons.js has no icon of that name)");
  }
  const html = { __html: markup }; // injection: markup from the kit's icon table only
  return (
    <span
      aria-hidden={label ? undefined : true}
      aria-label={label}
      className={className}
      dangerouslySetInnerHTML={html}
      role={label ? "img" : undefined}
      style={{ display: "inline-flex", lineHeight: 0 }}
    />
  );
}
