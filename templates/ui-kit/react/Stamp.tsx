/**
 * UI kit component for React projects: renders the kit's markup (styles/kit/kit.css), needs only React.
 */
import { useEffect, useState } from "react";

function ago(ms: number, now: number) {
  const s = Math.round((ms - now) / 1000);
  const a = Math.abs(s);
  const [n, unit]: [number, Intl.RelativeTimeFormatUnit] = a < 60 ? [s, "second"] : a < 3600 ? [Math.round(s / 60), "minute"] : a < 86400 ? [Math.round(s / 3600), "hour"] : [Math.round(s / 86400), "day"];
  try {
    return new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }).format(n, unit);
  } catch {
    return "";
  }
}

/** When the data is from: "Data as of 9 Oct 2026, 14:00 (2 hours ago)", kept up to date every minute. */
export function Stamp({ date, prefix = "Data as of" }: { date: string | Date; prefix?: string }) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 60000);
    return () => clearInterval(t);
  }, []);
  const d = date instanceof Date ? date : new Date(date);
  if (isNaN(d.getTime())) return null;
  let text: string;
  try {
    text = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(d);
  } catch {
    text = d.toLocaleString();
  }
  return (
    <span className="kit-stamp" title={d.toISOString()}>
      {prefix} {text} ({ago(d.getTime(), now)})
    </span>
  );
}
