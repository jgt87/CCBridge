import { Info } from "lucide-react";
import { useEffect, useState } from "react";
import type { BuildForm, ChatOptions, ProjectSetup, SetupChoice } from "@/lib/api";
import { BUILD_FORMS } from "@/lib/build-forms";
import { cn } from "@/lib/utils";


const LIVE_HELP =
  "A data file outside the project, for example in a SharePoint folder synced by OneDrive. StreamHub copies it into Source/Live/ whenever it changes and updates the pages; Scripts/Refresh-Data.ps1 does the same while StreamHub is closed.";
const PATH_HINT = "C:\\Users\\NAME\\Company\\Site - Documents\\data.csv";

// The API client is loaded when used: it reads the page's session token when loaded.
const loadApi = () => import("@/lib/api").then((m) => m.api);

const asList = <T,>(v: T[] | T | undefined): T[] => (Array.isArray(v) ? v : v ? [v] : []);

const choiceClass = (on: boolean) =>
  cn(
    "w-full rounded-md border px-2.5 py-1.5 text-left text-xs",
    on ? "border-foreground/40 bg-black/5 dark:bg-white/10" : "border-black/10 hover:bg-black/5 dark:border-white/10 dark:hover:bg-white/5",
  );
const buttonClass = "inline-flex items-center gap-1 rounded-md px-2.5 py-1 text-xs hover:bg-black/10 disabled:opacity-50 dark:hover:bg-white/15";
const inputClass = "w-full rounded-md border border-black/15 bg-transparent px-2 py-1 text-xs dark:border-white/15";

export interface SetupChoiceItem {
  kind: "setupChoice";
  seq: number;
  request: string;
  choices: SetupChoice[];
  live: boolean;
  suggest: string;
  clarify: boolean;
  restored: boolean;
}

/**
 * A new project's first request builds a page without saying how: one file, separate files or
 * Copilot's choice, and (with data) whether the data stays live from a file outside the project.
 * The answer sends the request again with the choice; StreamHub saves it for the project.
 */
export function SetupChoiceCard({ item, onSend }: { item: SetupChoiceItem; onSend?: (text: string, opts: ChatOptions) => void }) {
  const question = asList(item.choices)[0];
  const options = question ? asList(question.options) : BUILD_FORMS;
  const [build, setBuild] = useState<BuildForm>("single");
  const [live, setLive] = useState(Boolean(item.suggest));
  const [path, setPath] = useState(item.suggest);
  const [sent, setSent] = useState("");
  if (item.restored || sent) {
    return (
      <div className="flex items-start gap-2 px-1 text-muted-foreground text-sm">
        <Info className="mt-0.5 h-4 w-4" />
        <span>{sent || "StreamHub asked how this project should be built."}</span>
      </div>
    );
  }
  const send = () => {
    const label = options.find((o) => o.value === build)?.label ?? build;
    const source = live ? path.trim() : "";
    setSent(`Build form: ${label}${source ? `; live data from ${source}` : ""}. Sent to Copilot.`);
    const opts: ChatOptions = { setup: { build, liveSource: source || undefined } };
    if (item.clarify) opts.clarify = true;
    onSend?.(item.request, opts);
  };
  return (
    <div className="space-y-2 rounded-lg border border-black/10 px-3 py-2 text-sm dark:border-white/10">
      <div>{question?.question ?? "How should this be built?"} StreamHub remembers it for this project.</div>
      <div className="grid gap-1.5 sm:grid-cols-3">
        {options.map((o) => (
          <button aria-pressed={build === o.value} className={choiceClass(build === o.value)} key={o.value} onClick={() => setBuild(o.value as BuildForm)} type="button">
            <div className="font-medium">{o.label}</div>
            <div className="text-muted-foreground">{o.help}</div>
          </button>
        ))}
      </div>
      {item.live && (
        <div className="space-y-1">
          <label className="flex items-center gap-2 text-xs">
            <input checked={live} onChange={(e) => setLive(e.target.checked)} type="checkbox" />
            Keep the data live from a file outside the project
          </label>
          {live && (
            <>
              <input aria-label="Full path of the live data file" className={inputClass} onChange={(e) => setPath(e.target.value)} placeholder={PATH_HINT} value={path} />
              <div className="text-muted-foreground text-xs">{LIVE_HELP}</div>
            </>
          )}
        </div>
      )}
      <div className="flex gap-1.5">
        <button className={cn(buttonClass, "bg-black/5 dark:bg-white/10")} disabled={!onSend || (live && !path.trim())} onClick={send} type="button">
          Start building
        </button>
      </div>
    </div>
  );
}

/** Files tab > Project setup: the build form and the live data file of the open project, to change later. */
export function ProjectSetupPanel({ projectPath }: { projectPath: string }) {
  const [setup, setSetup] = useState<ProjectSetup | null>(null);
  const [path, setPath] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  // Loaded per project (the section is mounted again for another project).
  useEffect(() => {
    loadApi().then((api) => api.projectSetup()).then(
      (s) => {
        setSetup(s);
        setPath(s?.live?.path ?? "");
      },
      () => setSetup(null),
    );
  }, [projectPath]);
  const save = async (b: { build?: BuildForm | ""; liveSource?: string }, done: string) => {
    setBusy(true);
    setNote("");
    try {
      const r = await (await loadApi()).saveProjectSetup(b);
      setSetup(r.setup);
      setPath(r.setup.live?.path ?? "");
      setNote(done);
    } catch (e) {
      setNote((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  if (!setup) return <p className="text-muted-foreground text-xs">No project open.</p>;
  return (
    <div className="space-y-2 text-xs">
      <div className="space-y-1">
        <div className="text-muted-foreground">How pages are built (Copilot gets this with every task)</div>
        <div className="grid gap-1">
          {BUILD_FORMS.map((f) => (
            <button aria-pressed={setup.build === f.value} className={choiceClass(setup.build === f.value)} disabled={busy} key={f.value} onClick={() => void save({ build: f.value }, `Saved: ${f.label}.`)} title={f.help} type="button">
              {f.label}
            </button>
          ))}
        </div>
        {!setup.build && <div className="text-muted-foreground">Not chosen yet: StreamHub asks at the first request that builds a page.</div>}
      </div>
      <div className="space-y-1">
        <div className="text-muted-foreground">Live data file outside the project</div>
        <input aria-label="Full path of the live data file" className={inputClass} disabled={busy} onChange={(e) => setPath(e.target.value)} placeholder={PATH_HINT} value={path} />
        <div className="flex gap-1.5">
          <button className={cn(buttonClass, "bg-black/5 dark:bg-white/10")} disabled={busy || !path.trim() || path.trim() === setup.live?.path} onClick={() => void save({ liveSource: path.trim() }, "Saved: StreamHub copies the file in when it changes.")} type="button">
            Use this file
          </button>
          {setup.live && (
            <button className={buttonClass} disabled={busy} onClick={() => void save({ liveSource: "" }, "The live data file is no longer followed; the last copy stays.")} type="button">
              Stop following
            </button>
          )}
        </div>
        {setup.live ? (
          <div className="text-muted-foreground">
            Copied to {setup.live.copy}
            {setup.live.found ? "" : " (the file is not found right now: is its folder still synced?)"}.
          </div>
        ) : (
          <div className="text-muted-foreground">{LIVE_HELP}</div>
        )}
      </div>
      {note && <div className="text-muted-foreground">{note}</div>}
    </div>
  );
}
