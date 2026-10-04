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
  "w-full rounded-md border border-black/10 bg-transparent px-2 py-1 text-xs outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30";
const bigField =
  "w-full rounded-md border border-black/10 bg-transparent px-2 py-1 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30";
const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";

/** "web only · nodejs.org · 1 page · Analyst · 2 files": the header fields of a text runbook, or "" when it has none. */
export function webSummary(it: Pick<FetchItem, "sources" | "sites" | "pages" | "agent" | "files">): string {
  const parts: string[] = [];
  if (it.sources === "web") parts.push("web only");
  else if (it.sources === "work") parts.push("work data only");
  else if (it.sources === "both") parts.push("work data and web");
  if (it.sites?.trim()) parts.push(it.sites.trim());
  const n = (it.pages ?? "").split(/[\s,;]+/).filter((p) => /^https?:\/\//i.test(p)).length;
  if (n) parts.push(n === 1 ? "1 page" : `${n} pages`);
  const a = (it.agent ?? "").trim().toLowerCase();
  if (a === "researcher" || a === "analyst") parts.push(a === "researcher" ? "Researcher" : "Analyst");
  const f = (it.files ?? "").split(",").filter((x) => x.trim()).length;
  if (f) parts.push(f === 1 ? "1 file" : `${f} files`);
  return parts.join(" · ");
}

/** A new runbook with a text answer: its prompt, and where the data may come from and who answers. */
export function TextRunbookForm({ onSave, onCancel }: { onSave: (name: string, prompt: string, web: FetchWeb) => Promise<void>; onCancel: () => void }) {
  const [name, setName] = useState("");
  const [prompt, setPrompt] = useState("");
  const [sources, setSources] = useState<FetchWeb["sources"]>("");
  const [sites, setSites] = useState("");
  const [pages, setPages] = useState("");
  const [agent, setAgent] = useState<NonNullable<FetchWeb["agent"]>>("");
  const [files, setFiles] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  const save = async () => {
    setSaving(true);
    setError("");
    try {
      await onSave(name, prompt, { sources, sites, pages, agent, files });
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
      <div className="grid grid-cols-[auto_1fr] items-center gap-x-2 gap-y-1 text-xs">
        <span className="text-muted-foreground">Sources</span>
        <select aria-label="Sources" className={field} onChange={(e) => setSources(e.target.value as FetchWeb["sources"])} value={sources}>
          <option value="">As the prompt says</option>
          <option value="web">Web only</option>
          <option value="work">Work data only</option>
          <option value="both">Work data and the web</option>
        </select>
        <span className="text-muted-foreground">Sites</span>
        <input aria-label="Only these websites" className={field} onChange={(e) => setSites(e.target.value)} placeholder="Optional: only these websites, e.g. nodejs.org, python.org" value={sites} />
        <span className="text-muted-foreground">Pages</span>
        <input aria-label="Pages to read" className={field} onChange={(e) => setPages(e.target.value)} placeholder="Optional: pages to read exactly, e.g. https://nodejs.org/en/about/previous-releases" value={pages} />
        <span className="text-muted-foreground">Ask</span>
        <select aria-label="Who answers" className={field} onChange={(e) => setAgent(e.target.value as NonNullable<FetchWeb["agent"]>)} title="Researcher or Analyst answer instead of Copilot itself; they take several minutes" value={agent}>
          <option value="">Copilot</option>
          <option value="researcher">Researcher</option>
          <option value="analyst">Analyst</option>
        </select>
        <span className="text-muted-foreground">Files</span>
        <input aria-label="Files to attach" className={field} onChange={(e) => setFiles(e.target.value)} placeholder="Optional: project files to attach, e.g. Source/sales.csv" value={files} />
      </div>
      {error && <p className="text-rose-600 text-xs dark:text-rose-400">{error}</p>}
      <div className="flex justify-end gap-1">
        <button className={flatButton} onClick={onCancel} type="button">
          Cancel
        </button>
        <button className={cn(flatButton, "bg-black/5 dark:bg-white/10")} disabled={saving || !name.trim() || !prompt.trim()} onClick={save} type="button">
          {saving ? "Creating..." : "Create"}
        </button>
      </div>
    </div>
  );
}
