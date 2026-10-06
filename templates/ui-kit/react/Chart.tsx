/**
 * UI kit charts for React projects: draws with ../kit-charts.js (plain SVG on the kit's tokens),
 * needs only React. Design adapted from bklit-ui (MIT licence, see ../LICENSE-bklit-ui.txt).
 */
import { useEffect, useRef } from "react";
import "../kit-charts.js";

type Kind = "bar" | "line" | "area" | "ring" | "gauge" | "heatmap" | "sparkline";

declare global {
  interface Window {
    KitCharts: Record<Kind, (host: HTMLElement, data: unknown) => void>;
  }
}

/**
 * One chart. data follows kit-charts.js: bar/line/area { labels, series: [{ name, values }] },
 * ring { items: [{ label, value }], center }, gauge { value, max, label },
 * heatmap { rows, cols, values }, sparkline { values }. label describes the chart for screen readers.
 */
export function Chart({ kind, data, label, height }: { kind: Kind; data: unknown; label: string; height?: number }) {
  const host = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (host.current) window.KitCharts[kind](host.current, data);
  }, [kind, data]);
  return <div aria-label={label} className="kit-chart" data-kit-height={height} ref={host} />;
}
