/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { useState } from "react";

export interface CalendarEvent {
  date: string; // yyyy-mm-dd
  title: string;
  tone?: "ok" | "warn" | "error";
}

const isoDay = (d: Date) => d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2);
const fmt = (opts: Intl.DateTimeFormatOptions, d: Date, fallback: string) => {
  try {
    return new Intl.DateTimeFormat(undefined, opts).format(d);
  } catch {
    return fallback;
  }
};

/** A month with its events; Previous and Next change the month (onMonth), a click on a day calls onDay. */
export function Calendar({
  month,
  events,
  weekStart = 1,
  onDay,
  onMonth,
  label,
}: {
  month: string; // YYYY-MM
  events: CalendarEvent[];
  weekStart?: 0 | 1;
  onDay?: (date: string, events: CalendarEvent[]) => void;
  onMonth?: (month: string) => void;
  label?: string;
}) {
  const m = /^(\d{4})-(\d{2})$/.exec(month);
  const [now] = useState(() => new Date());
  const year = m ? Number(m[1]) : now.getFullYear();
  const mon = m ? Number(m[2]) - 1 : now.getMonth();
  const first = new Date(year, mon, 1);
  const lead = (first.getDay() - weekStart + 7) % 7;
  const cells = Math.ceil((lead + new Date(year, mon + 1, 0).getDate()) / 7) * 7;
  const today = isoDay(now);
  const step = (by: number) => {
    const d = new Date(year, mon + by, 1);
    onMonth?.(d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2));
  };
  const days = Array.from({ length: cells }, (_, c) => new Date(year, mon, 1 - lead + c));
  return (
    <div aria-label={label} className="kit-calendar">
      <div className="kit-calendar__head">
        <button className="kit-btn kit-btn--sm kit-btn--ghost" onClick={() => step(-1)} type="button">
          Previous
        </button>
        <h3 aria-live="polite" className="kit-calendar__title">
          {fmt({ month: "long", year: "numeric" }, first, year + "-" + (mon + 1))}
        </h3>
        <button className="kit-btn kit-btn--sm kit-btn--ghost" onClick={() => step(1)} type="button">
          Next
        </button>
      </div>
      <div className="kit-calendar__grid" role="grid">
        {Array.from({ length: 7 }, (_, d) => {
          const ref = new Date(2024, 0, 7 + ((weekStart + d) % 7)); // 7 Jan 2024 was a Sunday
          return (
            <div className="kit-calendar__dow" key={"dow" + d} role="columnheader">
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
              aria-label={name}
              className={"kit-calendar__day" + (day.getMonth() !== mon ? " is-other" : "") + (iso === today ? " is-today" : "")}
              data-date={iso}
              key={iso}
              onClick={() => onDay?.(iso, evs)}
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
