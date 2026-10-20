import { useState } from "react";
import type { FetchItem, FetchWeb } from "@/lib/api";
import { cn } from "@/lib/utils";

/** "12 min ago", "3 h ago", "2 days ago" or "never fetched". */
export function fetchedAge(iso: string | null, now = Date.now()): string {
  if (!iso) return "never fetched";
  const min = Math.max(0, Math.round((now - new Date(iso).getTime()) / 60000));
  if (min < 1) return "just now";
  if (min < 60) return `${min} min ago`;
  const h = Math.round(min / 60);
  if (h < 48) return `${h} h ago`;
  return `${Math.round(h / 24)} days ago`;
}

const field =
  "kit-input h-8 min-h-8 w-full text-xs";
const bigField =
  "kit-input h-8 min-h-8 w-full";
const flatButton =
  "kit-btn kit-btn--ghost kit-btn--sm";

const SOURCES_PART = new Map([
  ["web", "web only"],
  ["work", "work data only"],
  ["both", "work data and web"],
]);
const AGENT_PART = new Map([
  ["researcher", "Researcher"],
  ["analyst", "Analyst"],
]);

/** "1 page", "3 pages"; "" for none. */
const countPart = (n: number, one: string, many: string) => (n === 1 ? `1 ${one}` : n ? `${n} ${many}` : "");
/** The addresses (http or https) in a list separated by spaces, commas or semicolons. */
const pageCount = (pages: string) => pages.split(/[\s,;]+/).filter((p) => /^https?:\/\//i.test(p)).length;
/** The names in a comma-separated list. */
const fileCount = (files: string) => files.split(",").filter((x) => x.trim()).length;

/** "web only · nodejs.org · 1 page · Analyst · 2 files": the header fields of a text runbook, or "" when it has none. */
export function webSummary(it: Pick<FetchItem, "sources" | "sites" | "pages" | "agent" | "files">): string {
  return [
    SOURCES_PART.get(it.sources ?? "") ?? "",
    it.sites?.trim() ?? "",
    countPart(pageCount(it.pages ?? ""), "page", "pages"),
    AGENT_PART.get((it.agent ?? "").trim().toLowerCase()) ?? "",
    countPart(fileCount(it.files ?? ""), "file", "files"),
  ]
    .filter(Boolean)
    .join(" · ");
}

/** Where the data may come from, the sites and pages to read, who answers and the files to attach. */
function WebFields({ web, onChange }: { web: Required<FetchWeb>; onChange: (part: Partial<FetchWeb>) => void }) {
  return (
    <div className="grid grid-cols-[auto_1fr] items-center gap-x-2 gap-y-1 text-xs">
      <span className="text-muted-foreground">Sources</span>
      <select aria-label="Sources" className={field} onChange={(e) => onChange({ sources: e.target.value as FetchWeb["sources"] })} value={web.sources}>
        <option value="">As the prompt says</option>
        <option value="web">Web only</option>
        <option value="work">Work data only</option>
        <option value="both">Work data and the web</option>
      </select>
      <span className="text-muted-foreground">Sites</span>
      <input aria-label="Only these websites" className={field} onChange={(e) => onChange({ sites: e.target.value })} placeholder="Optional: only these websites, e.g. nodejs.org, python.org" value={web.sites} />
      <span className="text-muted-foreground">Pages</span>
      <input aria-label="Pages to read" className={field} onChange={(e) => onChange({ pages: e.target.value })} placeholder="Optional: pages to read exactly, e.g. https://nodejs.org/en/about/previous-releases" value={web.pages} />
      <span className="text-muted-foreground">Agent</span>
      <select aria-label="Who answers" className={field} onChange={(e) => onChange({ agent: e.target.value as NonNullable<FetchWeb["agent"]> })} title="Researcher or Analyst answer instead of Copilot itself; they take several minutes" value={web.agent}>
        <option value="">Copilot</option>
        <option value="researcher">Researcher</option>
        <option value="analyst">Analyst</option>
      </select>
      <span className="text-muted-foreground">Files</span>
      <input aria-label="Files to attach" className={field} onChange={(e) => onChange({ files: e.target.value })} placeholder="Optional: project files to attach, e.g. Source/sales.csv" value={web.files} />
    </div>
  );
}

/** A new runbook with a text answer: its prompt, and where the data may come from and who answers. */
export function TextRunbookForm({ onSave, onCancel }: { onSave: (name: string, prompt: string, web: FetchWeb) => Promise<void>; onCancel: () => void }) {
  const [name, setName] = useState("");
  const [prompt, setPrompt] = useState("");
  const [web, setWeb] = useState<Required<FetchWeb>>({ sources: "", sites: "", pages: "", agent: "", files: "" });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  const save = async () => {
    setSaving(true);
    setError("");
    try {
      await onSave(name, prompt, web);
      onCancel();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-2">
      <input aria-label="Runbook name" className={bigField} onChange={(e) => setName(e.target.value)} placeholder="Name, e.g. meetings today" value={name} />
      <textarea
        aria-label="What Copilot should get"
        className={cn(bigField, "min-h-24 resize-y")}
        onChange={(e) => setPrompt(e.target.value)}
        placeholder="What to get, e.g. List my meetings for today with times, attendees and the agenda."
        value={prompt}
      />
      <WebFields onChange={(part) => setWeb((w) => ({ ...w, ...part }))} web={web} />
      {error && <p className="kit-error-text">{error}</p>}
      <div className="flex justify-end gap-1">
        <button className={flatButton} onClick={onCancel} type="button">
          Cancel
        </button>
        <button className={cn(flatButton, "bg-(--kit-surface-2)")} disabled={saving || !name.trim() || !prompt.trim()} onClick={save} type="button">
          {saving ? "Creating..." : "Create"}
        </button>
      </div>
    </div>
  );
}
