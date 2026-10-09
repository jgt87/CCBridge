/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { useState } from "react";

export interface Period {
  preset: string;
  from: string; // yyyy-mm-dd, included; "" for all
  to: string;
}

const NAMES: Record<string, string> = {
  "7d": "Last 7 days",
  "30d": "Last 30 days",
  "90d": "Last 90 days",
  week: "This week",
  month: "This month",
  quarter: "This quarter",
  year: "This year",
  all: "All",
  custom: "Custom",
};

const isoDay = (d: Date) => d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2);

/** The dates of a period ("30d", "week", "month", "quarter", "year", "all"); the week starts on weekStart (1 Monday, 0 Sunday). */
export function periodOf(preset: string, weekStart: 0 | 1 = 1): { from: string; to: string } {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let from: Date | null = null;
  const days = /^(\d+)d$/.exec(preset);
  if (days) {
    from = new Date(today);
    from.setDate(from.getDate() - (parseInt(days[1], 10) - 1));
  } else if (preset === "week") {
    from = new Date(today);
    from.setDate(from.getDate() - ((today.getDay() - weekStart + 7) % 7));
  } else if (preset === "month") from = new Date(today.getFullYear(), today.getMonth(), 1);
  else if (preset === "quarter") from = new Date(today.getFullYear(), Math.floor(today.getMonth() / 3) * 3, 1);
  else if (preset === "year") from = new Date(today.getFullYear(), 0, 1);
  return from ? { from: isoDay(from), to: isoDay(today) } : { from: "", to: "" };
}

/** A period filter: buttons for the periods and date fields for a custom one. */
export function PeriodFilter({
  value,
  onChange,
  presets = ["7d", "30d", "month", "quarter", "year", "all", "custom"],
  weekStart = 1,
  label = "Period",
}: {
  value: string;
  onChange: (period: Period) => void;
  presets?: string[];
  weekStart?: 0 | 1;
  label?: string;
}) {
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const choose = (p: string) => {
    if (p === "custom") {
      onChange({ preset: p, from, to });
      return;
    }
    onChange({ preset: p, ...periodOf(p, weekStart) });
  };
  const dates = (f: string, t: string) => {
    const [a, b] = f && t && f > t ? [t, f] : [f, t];
    setFrom(a);
    setTo(b);
    onChange({ preset: "custom", from: a, to: b });
  };
  return (
    <div aria-label={label} className={"kit-range" + (value !== "all" ? " is-active" : "")}>
      <div aria-label={label} className="kit-segmented" role="group">
        {presets.map((p) => (
          <button aria-pressed={value === p} key={p} onClick={() => choose(p)} type="button">
            {NAMES[p] ?? "Last " + parseInt(p, 10) + " days"}
          </button>
        ))}
      </div>
      <span className="kit-range__custom" hidden={value !== "custom"}>
        <input aria-label="From" className="kit-input" onChange={(e) => dates(e.target.value, to)} type="date" value={from} />
        <span aria-hidden="true">-</span>
        <input aria-label="To" className="kit-input" onChange={(e) => dates(from, e.target.value)} type="date" value={to} />
      </span>
    </div>
  );
}
