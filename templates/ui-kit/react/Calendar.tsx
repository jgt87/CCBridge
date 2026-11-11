/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { useEffect, useRef, useState, type KeyboardEvent } from "react";

export interface CalendarEvent {
  date: string; // yyyy-mm-dd
  title: string;
  tone?: "ok" | "warn" | "error";
}

const isoDay = (d: Date) => d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2);
const isoMonth = (d: Date) => isoDay(d).slice(0, 7);
const fmt = (opts: Intl.DateTimeFormatOptions, d: Date, fallback: string) => {
  try {
    return new Intl.DateTimeFormat(undefined, opts).format(d);
  } catch {
    return fallback;
  }
};

/** The week's first day (0 = Sunday ... 6) when the page gives none: the kit's setting (--kit-week-start),
 *  else the day the browser's language starts on, else Monday. The same order as kit.js. */
export function defaultWeekStart(): number {
  try {
    const css = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--kit-week-start"), 10);
    if (css >= 0 && css <= 6) return css;
    const loc = new Intl.Locale(navigator.language) as Intl.Locale & { getWeekInfo?: () => { firstDay: number }; weekInfo?: { firstDay: number } };
    const info = loc.getWeekInfo ? loc.getWeekInfo() : loc.weekInfo;
    if (info && info.firstDay >= 1 && info.firstDay <= 7) return info.firstDay % 7; // 7 = Sunday
  } catch {
    // a browser without week data: Monday
  }
  return 1;
}

/** A month with its events; Previous, Next and Today change the month (onMonth), a click on a day calls onDay.
 *  The days are one tab stop: arrow keys move a day or a week, Home and End go to the week's first and last
 *  day, PageUp and PageDown a month (with Shift a year). */
export function Calendar({
  month,
  events,
  weekStart,
  onDay,
  onMonth,
  label,
}: {
  month: string; // YYYY-MM
  events: CalendarEvent[];
  weekStart?: 0 | 1 | 2 | 3 | 4 | 5 | 6;
  onDay?: (date: string, events: CalendarEvent[]) => void;
  onMonth?: (month: string) => void;
  label?: string;
}) {
  const m = /^(\d{4})-(\d{2})$/.exec(month);
  const [now] = useState(() => new Date());
  const [ownStart] = useState(defaultWeekStart);
  const start = weekStart ?? ownStart;
  const year = m ? Number(m[1]) : now.getFullYear();
  const mon = m ? Number(m[2]) - 1 : now.getMonth();
  const first = new Date(year, mon, 1);
  const lead = (first.getDay() - start + 7) % 7;
  const cells = Math.ceil((lead + new Date(year, mon + 1, 0).getDate()) / 7) * 7;
  const today = isoDay(now);
  const days = Array.from({ length: cells }, (_, c) => new Date(year, mon, 1 - lead + c));
  const shown = days.map(isoDay);
  // The day that takes the Tab key: the one last focused while it is on show, else today, else the 1st.
  const [focusDay, setFocusDay] = useState("");
  const tabDay = shown.includes(focusDay) ? focusDay : isoMonth(now) === isoMonth(first) ? today : isoDay(first);
  const grid = useRef<HTMLDivElement>(null);
  const wanted = useRef(""); // the day to focus once its month is drawn
  useEffect(() => {
    if (!wanted.current) return;
    const b = grid.current?.querySelector<HTMLElement>('[data-date="' + wanted.current + '"]');
    if (b) {
      wanted.current = "";
      b.focus();
    }
  });
  const show = (d: Date) => {
    if (isoMonth(d) !== isoMonth(first)) onMonth?.(isoMonth(d));
  };
  const go = (to: Date, turn: boolean) => {
    const iso = isoDay(to);
    setFocusDay(iso);
    wanted.current = iso;
    if (turn || !shown.includes(iso)) show(to);
  };
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const day = (e.target as HTMLElement).closest<HTMLElement>(".kit-calendar__day");
    if (!day || e.altKey || e.ctrlKey || e.metaKey) return;
    const p = (day.getAttribute("data-date") || "").split("-").map(Number);
    const [y, mo, d] = [p[0], p[1] - 1, p[2]];
    const col = (new Date(y, mo, d).getDay() - start + 7) % 7;
    const steps: Record<string, number> = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7, Home: -col, End: 6 - col };
    if (Object.prototype.hasOwnProperty.call(steps, e.key)) {
      e.preventDefault();
      go(new Date(y, mo, d + steps[e.key]), false);
      return;
    }
    if (e.key !== "PageUp" && e.key !== "PageDown") return;
    e.preventDefault();
    const by = (e.key === "PageUp" ? -1 : 1) * (e.shiftKey ? 12 : 1);
    go(new Date(y, mo + by, Math.min(d, new Date(y, mo + by + 1, 0).getDate())), true); // 31 March -> 30 April
  };
  const title = fmt({ month: "long", year: "numeric" }, first, year + "-" + (mon + 1));
  return (
    <div aria-label={label} className="kit-calendar">
      <div className="kit-calendar__head">
        <button className="kit-btn kit-btn--sm kit-btn--ghost" data-step="-1" onClick={() => show(new Date(year, mon - 1, 1))} type="button">
          Previous
        </button>
        <h3 aria-live="polite" className="kit-calendar__title">
          {title}
        </h3>
        <span className="kit-calendar__nav">
          <button
            className="kit-btn kit-btn--sm kit-btn--ghost"
            data-today=""
            onClick={() => {
              setFocusDay(today);
              show(now);
            }}
            type="button"
          >
            Today
          </button>
          <button className="kit-btn kit-btn--sm kit-btn--ghost" data-step="1" onClick={() => show(new Date(year, mon + 1, 1))} type="button">
            Next
          </button>
        </span>
      </div>
      {/* A group of day buttons named by the month (as in kit.js): a grid role would need rows and grid cells. */}
      <div aria-label={title} className="kit-calendar__grid" onKeyDown={onKey} ref={grid} role="group">
        {Array.from({ length: 7 }, (_, d) => {
          const ref = new Date(2024, 0, 7 + ((start + d) % 7)); // 7 Jan 2024 was a Sunday
          return (
            <div aria-hidden="true" className="kit-calendar__dow" key={"dow" + d}>
              {fmt({ weekday: "short" }, ref, ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][ref.getDay()])}
            </div>
          );
        })}
        {days.map((day) => {
          const iso = isoDay(day);
          const evs = events.filter((ev) => String(ev.date).slice(0, 10) === iso);
          const name = fmt({ dateStyle: "full" }, day, iso) + (evs.length ? ", " + evs.length + " item" + (evs.length > 1 ? "s" : "") : "");
          return (
            <button
              aria-current={iso === today ? "date" : undefined}
              aria-label={name}
              className={"kit-calendar__day" + (day.getMonth() !== mon ? " is-other" : "") + (iso === today ? " is-today" : "")}
              data-date={iso}
              key={iso}
              onClick={() => onDay?.(iso, evs)}
              onFocus={() => setFocusDay(iso)}
              tabIndex={iso === tabDay ? 0 : -1}
              type="button"
            >
              <span className="kit-calendar__num">{day.getDate()}</span>
              {evs.slice(0, 3).map((ev, i) => (
                <span className={"kit-calendar__event" + (ev.tone ? " kit-calendar__event--" + ev.tone : "")} key={i}>
                  {ev.title}
                </span>
              ))}
              {evs.length > 3 ? <span className="kit-calendar__event">+{evs.length - 3}</span> : null}
            </button>
          );
        })}
      </div>
    </div>
  );
}
