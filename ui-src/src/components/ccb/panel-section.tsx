import { ChevronRight } from "lucide-react";
import type React from "react";
import { useState } from "react";
import { cn } from "@/lib/utils";

const storageKey = (id: string) => `ccb.section.${id}`;

/** Opens a section (remembered as open) before it is shown, for links that lead to it. */
export function openSection(id: string) {
  try {
    localStorage.setItem(storageKey(id), "1");
  } catch {
    /* storage blocked */
  }
}

function readOpen(id: string, fallback: boolean) {
  try {
    const v = localStorage.getItem(storageKey(id));
    return v === null ? fallback : v === "1";
  } catch {
    return fallback;
  }
}

/**
 * One section of the side panel: a small uppercase title (with an optional badge and buttons on
 * the right), a divider above every section but the first, and content that folds away. Whether
 * a section is open is remembered in this browser. Pass `open` / `onOpenChange` to control it.
 */
export function PanelSection({
  id,
  title,
  badge,
  actions,
  summary,
  defaultOpen = true,
  open: openProp,
  onOpenChange,
  className,
  children,
}: {
  id: string;
  title: string;
  /** Next to the title, e.g. a Beta tag or a count. */
  badge?: React.ReactNode;
  /** Buttons on the right of the title row (they do not fold the section). */
  actions?: React.ReactNode;
  /** A short line shown instead of the content while the section is folded. */
  summary?: React.ReactNode;
  defaultOpen?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  className?: string;
  children: React.ReactNode;
}) {
  const [own, setOwn] = useState(() => readOpen(id, defaultOpen));
  const open = openProp ?? own;
  const setOpen = (v: boolean) => {
    setOwn(v);
    onOpenChange?.(v);
    try {
      localStorage.setItem(storageKey(id), v ? "1" : "0");
    } catch {
      /* storage blocked: only this session remembers it */
    }
  };

  return (
    <section className={cn("scroll-mt-2 border-black/10 border-t first:border-t-0 dark:border-white/10", className)} id={`section-${id}`}>
      <div className="flex h-9 items-center gap-1 px-2">
        <button
          aria-expanded={open}
          className="flex min-w-0 flex-1 items-center gap-1.5 rounded-md px-1 py-1 text-left text-muted-foreground hover:text-foreground"
          onClick={() => setOpen(!open)}
          title={open ? `Fold ${title}` : `Show ${title}`}
          type="button"
        >
          <ChevronRight className={cn("h-3.5 w-3.5 shrink-0 transition-transform", open && "rotate-90")} />
          <span className="truncate font-medium text-[11px] uppercase tracking-wide">{title}</span>
          {badge}
        </button>
        {actions && <div className="flex shrink-0 items-center gap-0.5">{actions}</div>}
      </div>
      {open ? <div className="px-3 pb-3">{children}</div> : summary ? <div className="-mt-1 truncate px-3 pb-2 text-muted-foreground text-xs">{summary}</div> : null}
    </section>
  );
}

/** A small icon button for a section's title row. */
export function SectionButton({ title, onClick, disabled, children }: { title: string; onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return (
    <button
      className="rounded p-1 text-muted-foreground hover:bg-black/5 hover:text-foreground disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5"
      disabled={disabled}
      onClick={onClick}
      title={title}
      type="button"
    >
      {children}
    </button>
  );
}

/** A small grey count next to a section title. */
export function SectionCount({ n }: { n: number }) {
  return <span className="rounded px-1 text-[10px] text-muted-foreground tabular-nums ring-1 ring-black/10 dark:ring-white/15">{n}</span>;
}
