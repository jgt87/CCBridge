import { AtSign, CalendarClock, FileText, Plus, RefreshCw } from "lucide-react";
import { useState } from "react";
import type { FetchItem } from "@/lib/api";
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

const flatButton =
  "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:hover:bg-white/5";

/** Fetch tab: saved prompts that get current data from Copilot into a file you can attach with @. */
export function FetchPanel({
  items,
  busy,
  onRun,
  onSave,
  onAttach,
  onOpen,
  onSchedule,
}: {
  onSchedule?: (name: string) => void;
  items: FetchItem[];
  busy: boolean;
  onRun: (name: string) => void;
  onSave: (name: string, prompt: string) => Promise<void>;
  onAttach: (path: string) => void;
  onOpen: (path: string) => void;
}) {
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState("");
  const [prompt, setPrompt] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  const save = async () => {
    setSaving(true);
    setError("");
    try {
      await onSave(name, prompt);
      setName("");
      setPrompt("");
      setAdding(false);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-2">
      <p className="text-muted-foreground text-xs">
        Saved prompts that fetch current data, such as today's meetings. Each run writes Copilot's answer to a file in <span className="font-mono">Runbooks/Exports/</span> (earlier answers in <span className="font-mono">History/</span>); attach it to a message with @.
      </p>

      {adding ? (
        <div className="space-y-2 rounded-lg border border-black/10 p-2 dark:border-white/10">
          <input
            className="w-full rounded-md border border-black/10 bg-transparent px-2 py-1 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30"
            onChange={(e) => setName(e.target.value)}
            placeholder="Name, e.g. meetings today"
            value={name}
          />
          <textarea
            className="min-h-24 w-full resize-y rounded-md border border-black/10 bg-transparent px-2 py-1 text-sm outline-none focus:border-black/30 dark:border-white/10 dark:focus:border-white/30"
            onChange={(e) => setPrompt(e.target.value)}
            placeholder="Prompt, e.g. List my meetings for today with times, attendees and the agenda."
            value={prompt}
          />
          {error && <p className="text-rose-600 text-xs dark:text-rose-400">{error}</p>}
          <div className="flex justify-end gap-1">
            <button className={flatButton} onClick={() => setAdding(false)} type="button">
              Cancel
            </button>
            <button className={cn(flatButton, "bg-black/5 dark:bg-white/10")} disabled={saving || !name.trim() || !prompt.trim()} onClick={save} type="button">
              {saving ? "Saving..." : "Save"}
            </button>
          </div>
        </div>
      ) : (
        <button className={cn(flatButton, "w-full justify-center border border-black/10 py-1.5 dark:border-white/10")} onClick={() => setAdding(true)} type="button">
          <Plus className="h-3.5 w-3.5" /> New fetch prompt
        </button>
      )}

      {items.length === 0 && !adding && <p className="pt-1 text-muted-foreground text-sm">No fetch prompts yet.</p>}

      {items.map((it) => (
        <div className="rounded-lg border border-black/10 p-2 dark:border-white/10" key={it.name}>
          <div className="flex items-center gap-2">
            <span className="truncate font-medium text-sm" title={it.prompt}>
              {it.name}
            </span>
            <span className="ml-auto shrink-0 text-muted-foreground text-xs" title={it.fetchedAt ? new Date(it.fetchedAt).toLocaleString() : undefined}>
              {fetchedAge(it.fetchedAt)}
            </span>
          </div>
          <p className="mt-0.5 line-clamp-2 text-muted-foreground text-xs" title={it.prompt}>
            {it.prompt}
          </p>
          <div className="mt-1.5 flex gap-1">
            <button className={flatButton} onClick={() => onRun(it.name)} title={busy ? "Add it to the queue; the answer is saved when it runs" : "Ask Copilot now and save the answer"} type="button">
              <RefreshCw className="h-3 w-3" /> {it.fetchedAt ? "Refresh" : "Run"}
            </button>
            {onSchedule && (
              <button className={flatButton} onClick={() => onSchedule(it.name)} title="Fetch it on set days and times" type="button">
                <CalendarClock className="h-3 w-3" /> Schedule
              </button>
            )}
            <button className={flatButton} disabled={!it.fetchedAt} onClick={() => onAttach(it.output)} title={`Attach @${it.output} to your message`} type="button">
              <AtSign className="h-3 w-3" /> Attach
            </button>
            <button className={flatButton} disabled={!it.fetchedAt} onClick={() => onOpen(it.output)} title={it.output} type="button">
              <FileText className="h-3 w-3" /> View
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}
