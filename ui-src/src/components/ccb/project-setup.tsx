import { Hammer, Info } from "lucide-react";
import { useEffect, useState } from "react";
import HoldButton from "@/components/kokonutui/hold-button";
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
  const questions = asList(item.choices);
  const buildQ = questions.find((q) => q.id === "build");
  const others = questions.filter((q) => q.id !== "build");
  const options = buildQ ? asList(buildQ.options) : BUILD_FORMS;
  const [build, setBuild] = useState<BuildForm>("single");
  const [live, setLive] = useState(Boolean(item.suggest));
  const [path, setPath] = useState(item.suggest);
  // The first choice of every other question is the usual one; a multi-select starts empty.
  const [answers, setAnswers] = useState<Record<string, string>>(() => Object.fromEntries(others.map((q) => [q.id, q.multi ? "" : (asList(q.options)[0]?.value ?? "")])));
  const [sent, setSent] = useState("");
  if (item.restored || sent) {
    return (
      <div className="flex items-start gap-2 px-1 text-muted-foreground text-sm">
        <Info className="mt-0.5 h-4 w-4" />
        <span>{sent || "StreamHub asked how this should be built."}</span>
      </div>
    );
  }
  const labelOf = (q: SetupChoice, v: string) =>
    v
      .split(",")
      .filter(Boolean)
      .map((x) => asList(q.options).find((o) => o.value === x)?.label ?? x)
      .join(", ") || "none";
  const toggle = (q: SetupChoice, v: string) =>
    setAnswers((a) => {
      if (!q.multi) return { ...a, [q.id]: v };
      const set = new Set((a[q.id] || "").split(",").filter(Boolean));
      if (set.has(v)) set.delete(v);
      else set.add(v);
      return { ...a, [q.id]: [...set].join(",") };
    });
  const send = () => {
    const parts: string[] = [];
    if (buildQ) {
      const label = options.find((o) => o.value === build)?.label ?? build;
      parts.push(`Build form: ${label}${live && path.trim() ? `; live data from ${path.trim()}` : ""}`);
    }
    for (const q of others) parts.push(`${q.question.replace(/\?$/, "")}: ${labelOf(q, answers[q.id] || "")}`);
    // Answers that mean "not now": nothing is sent, the note says what to do.
    if (answers.addto === "project") {
      setSent(`${parts.join("; ")}. Create the new project in the project list, open it, and send the request there.`);
      return;
    }
    if (answers.sampledata === "wait") {
      setSent(`${parts.join("; ")}. Add the data file to the project (Source/ or the project folder), then send the request again.`);
      return;
    }
    setSent(`${parts.join("; ")}. Sent to Copilot.`);
    const opts: ChatOptions = { setup: { ...(buildQ ? { build, liveSource: live ? path.trim() || undefined : undefined } : {}), answers } };
    if (item.clarify || answers.bigtask === "clarify") opts.clarify = true;
    if (answers.bigtask === "plan") {
      opts.planFirst = true;
      opts.request = item.request;
    }
    onSend?.(item.request, opts);
  };
  const choiceGrid = (q: SetupChoice) => {
    const opts = asList(q.options);
    const chosen = new Set((answers[q.id] || "").split(",").filter(Boolean));
    return (
      <div className="grid gap-1.5 sm:grid-cols-3" key={q.id}>
        {opts.map((o) => {
          const on = q.multi ? chosen.has(o.value) : answers[q.id] === o.value;
          return (
            <button aria-pressed={on} className={choiceClass(on)} key={o.value} onClick={() => toggle(q, o.value)} role={q.multi ? "checkbox" : undefined} aria-checked={q.multi ? on : undefined} type="button">
              <div className="font-medium">{o.label}</div>
              <div className="text-muted-foreground">{o.help}</div>
            </button>
          );
        })}
      </div>
    );
  };
  return (
    <div className="space-y-3 rounded-lg border border-black/10 px-3 py-2 text-sm dark:border-white/10">
      {buildQ && (
        <div className="space-y-2">
          <div>{buildQ.question} StreamHub remembers it for this project.</div>
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
        </div>
      )}
      {others.map((q) => (
        <div className="space-y-1.5" key={q.id}>
          <div>
            {q.question}
            {q.multi && <span className="text-muted-foreground text-xs"> (choose any)</span>}
            {q.scope === "request" && <span className="text-muted-foreground text-xs"> (for this request)</span>}
          </div>
          {choiceGrid(q)}
        </div>
      ))}
      {/* Held like the run approval: the same button, size and fill, so nothing starts on a stray click. */}
      <div className="flex flex-wrap items-center gap-2">
        <HoldButton
          className="h-10 min-w-44"
          disabled={!onSend || (buildQ && live && !path.trim())}
          holdDuration={1200}
          holdingLabel="Keep holding..."
          icon={<Hammer className="h-4 w-4" />}
          label={answers.addto === "project" || answers.sampledata === "wait" ? "Hold to confirm" : "Hold to start building"}
          onHoldComplete={send}
          variant="grey"
        />
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
  const save = async (b: { build?: BuildForm | ""; liveSource?: string; forget?: string }, done: string) => {
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
      {setup.answers && setup.answers.length > 0 && (
        <div className="space-y-1">
          <div className="text-muted-foreground">Choices made for this project (asked when a request needed them; Copilot gets them with every task)</div>
          {setup.answers.map((a) => (
            <div className="flex items-center gap-2" key={a.id}>
              <span className="truncate" title={a.question}>
                {a.label}
              </span>
              <button className={cn(buttonClass, "ml-auto shrink-0")} disabled={busy} onClick={() => void save({ forget: a.id }, `Forgotten: ${a.question} StreamHub asks again when a request needs it.`)} type="button">
                Forget
              </button>
            </div>
          ))}
        </div>
      )}
      {note && <div className="text-muted-foreground">{note}</div>}
    </div>
  );
}
