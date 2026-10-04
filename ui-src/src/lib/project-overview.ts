import type { ProjectOverview } from "@/lib/api";

/** 950 B, 12 KB, 3.4 MB, 1.2 GB. */
export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = n / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v >= 10 ? Math.round(v) : Math.round(v * 10) / 10} ${units[i]}`;
}

/** "42 files · 1.2 MB · HTML, JavaScript, CSS · source data"; empty when there is nothing to say. */
export function overviewText(o: ProjectOverview | null | undefined): string {
  if (!o) return "";
  if (!o.files) return "empty";
  const parts = [`${o.capped ? "5000+" : o.files} file${o.files === 1 ? "" : "s"}`, formatBytes(o.bytes)];
  const langs = Array.isArray(o.languages) ? o.languages : o.languages ? [String(o.languages)] : [];
  if (langs.length) parts.push(langs.join(", "));
  if (o.sourceFiles) parts.push("source data");
  return parts.join(" · ");
}
