/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 * The kit-shell of kit.js's data-kit-shell-menu: band header, side navigation, main part.
 */
import { type MouseEvent, type ReactNode, useEffect, useId, useRef, useState } from "react";
import { Icon } from "./Icon";

export interface ShellLink {
  href: string;
  label: string;
  current?: boolean;
  icon?: ReactNode;
  onClick?: (e: MouseEvent<HTMLAnchorElement>) => void;
}

/**
 * An app with sections: the band header (title, then actions such as ThemeToggle), the navigation at the
 * side (behind a menu button on a narrow screen: a link or Escape closes it) and the main part.
 */
export function AppShell({ title, links, actions, children, navLabel = "Sections", mainId = "main" }: { title: ReactNode; links: ShellLink[]; actions?: ReactNode; children: ReactNode; navLabel?: string; mainId?: string }) {
  const [open, setOpen] = useState(false);
  const navId = useId();
  const button = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!open) return;
    const esc = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented) return;
      e.preventDefault();
      setOpen(false);
      button.current?.focus();
    };
    document.addEventListener("keydown", esc);
    return () => document.removeEventListener("keydown", esc);
  }, [open]);
  return (
    <div className="kit-shell">
      <a className="kit-skip" href={"#" + mainId}>
        Skip to content
      </a>
      <header className="kit-header kit-header--band">
        <div className="kit-container">
          <p className="kit-header__title">{title}</p>
          <div className="kit-row">
            {actions}
            <button aria-controls={navId} aria-expanded={open} aria-label="Menu" className="kit-btn kit-btn--ghost kit-btn--icon kit-shell__menu" onClick={() => setOpen((o) => !o)} ref={button} type="button">
              <Icon name="menu" />
            </button>
          </div>
        </div>
      </header>
      <nav aria-label={navLabel} className={"kit-shell__nav kit-nav" + (open ? " is-open" : "")} id={navId}>
        {links.map((l) => (
          <a
            aria-current={l.current ? "page" : undefined}
            className="kit-nav__item"
            href={l.href}
            key={l.href}
            onClick={(e) => {
              setOpen(false);
              l.onClick?.(e);
            }}
          >
            {l.icon}
            {l.label}
          </a>
        ))}
      </nav>
      <main className="kit-shell__main kit-container" id={mainId} tabIndex={-1}>
        {children}
      </main>
    </div>
  );
}
