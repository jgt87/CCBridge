/**
 * UI kit charts for React projects: draws with ../kit-charts.js (plain SVG on the kit's tokens),
 * needs only React. Design adapted from bklit-ui (MIT licence, see ../LICENSE-bklit-ui.txt).
 */
import { useEffect, useRef } from "react";
import "../kit-charts.js";

type Kind = "bar" | "line" | "area" | "ring" | "gauge" | "heatmap" | "sparkline" | "barlist";

/** What a click on a chart part picked (data.selectable): see kit-charts.js. */
export type ChartPick = {
  chart: string;
  part: "bar" | "arc" | "row" | "legend";
  value: string;
  index: number;
  series?: string;
  seriesIndex?: number;
};

declare global {
  interface Window {
    KitCharts: Record<Kind, (host: HTMLElement, data: unknown) => void>;
  }
}

/**
 * One chart. data follows kit-charts.js: bar/line/area { labels, series: [{ name, values }],
 * stacked (bar); a bar series with type: "line" (axis: "right") is a line over the bars },
 * ring { items: [{ label, value, color }], center, legend: "values" },
 * barlist { items: [{ label, value, color }], limit, share, total, base: "first" (a funnel) },
 * where color is a meaning (ok, warn, error, muted, accent) or chart-1 ... chart-6,
 * gauge { value, max, label },
 * heatmap { rows, cols, values }, sparkline { values }. For filtering: data.selectable,
 * data.selected (labels), data.selectedSeries (series names) and onSelect.
 * label describes the chart for screen readers.
 */
export function Chart({
  kind,
  data,
  label,
  height,
  onSelect,
}: {
  kind: Kind;
  data: unknown;
  label: string;
  height?: number;
  onSelect?: (pick: ChartPick) => void;
}) {
  const host = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (host.current) window.KitCharts[kind](host.current, data);
  }, [kind, data]);
  useEffect(() => {
    const el = host.current;
    if (!el || !onSelect) return;
    const handle = (e: Event) => onSelect((e as CustomEvent<ChartPick>).detail);
    el.addEventListener("kit:select", handle);
    return () => el.removeEventListener("kit:select", handle);
  }, [onSelect]);
  return <div aria-label={label} className="kit-chart" data-kit-height={height} ref={host} />;
}
