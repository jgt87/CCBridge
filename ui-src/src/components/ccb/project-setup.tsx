import { Hammer, Info } from "lucide-react";
import { useEffect, useState } from "react";
import HoldButton from "@/components/kokonutui/hold-button";
import type { BuildForm, ChatOptions, ProjectSetup, SetupAnswer, SetupChoice } from "@/lib/api";
import { BUILD_FORMS } from "@/lib/build-forms";
import { asList, holdsRequest, initialAnswers, isChosen, type SetupOption, setupReply, toggleAnswer } from "@/lib/project-setup-view";
import { cn } from "@/lib/utils";
import { DatabasesSection } from "./databases-section";
import { SharePointSection } from "./sharepoint-section";
import { WebAllowSection } from "./web-allow-section";


const LIVE_HELP =
  "A data file outside the project, for example in a SharePoint folder synced by OneDrive. StreamHub copies it into Source/Live/ whenever it changes and updates the pages; Scripts/Refresh-Data.ps1 does the same while StreamHub is closed.";
const PATH_HINT = "C:\\Users\\NAME\\Company\\Site - Documents\\data.csv";

// The API client is loaded when used: it reads the page's session token when loaded.
const loadApi = () => import("@/lib/api").then((m) => m.api);

const choiceClass = (on: boolean) =>
  cn(
    "kit-btn kit-btn--sm h-auto min-h-0 w-full flex-col items-start justify-start px-2.5 py-1.5 text-left font-normal text-xs",
    on ? "border-(--kit-border-strong) bg-(--kit-accent-soft)" : "border-(--kit-border)",
  );
const buttonClass = "kit-btn kit-btn--ghost kit-btn--sm";
const inputClass = "kit-input h-8 min-h-8 w-full text-xs";

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

/** One option of a question: its label and what it means. */
function OptionButton({ option, on, multi, onPick }: { option: SetupOption; on: boolean; multi?: boolean; onPick: () => void }) {
  return (
    <button aria-pressed={on} className={choiceClass(on)} onClick={onPick} role={multi ? "checkbox" : undefined} aria-checked={multi ? on : undefined} type="button">
      <div className="font-medium">{option.label}</div>
      <div className="text-muted-foreground">{option.help}</div>
    </button>
  );
}

/** The live data file: a tick box, and the path once ticked. */
function LiveDataField({ live, setLive, path, setPath }: { live: boolean; setLive: (on: boolean) => void; path: string; setPath: (p: string) => void }) {
  return (
    <div className="space-y-1">
      <label className="kit-check text-xs">
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
  );
}

/** One of the other questions: its text, a note for optional or per-request ones, and its options. */
function SetupQuestion({ q, value, onPick }: { q: SetupChoice; value: string; onPick: (option: string) => void }) {
  return (
    <div className="space-y-1.5">
      <div>
        {q.question}
        {q.multi && <span className="text-muted-foreground text-xs"> (optional: pick any, or none)</span>}
        {q.scope === "request" && <span className="text-muted-foreground text-xs"> (for this request)</span>}
      </div>
      <div className="grid gap-1.5 sm:grid-cols-3">
        {asList(q.options).map((o) => (
          <OptionButton key={o.value} multi={q.multi} on={isChosen(q, value, o.value)} onPick={() => onPick(o.value)} option={o} />
        ))}
      </div>
    </div>
  );
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
  const [answers, setAnswers] = useState<Record<string, string>>(() => initialAnswers(others));
  const [sent, setSent] = useState("");
  if (item.restored || sent) {
    return (
      <div className="flex items-start gap-2 px-1 text-muted-foreground text-sm">
        <Info className="mt-0.5 h-4 w-4" />
        <span>{sent || "StreamHub asked how this should be built."}</span>
      </div>
    );
  }
  const pick = (q: SetupChoice, option: string) => setAnswers((a) => ({ ...a, [q.id]: toggleAnswer(q, a[q.id] || "", option) }));
  const send = () => {
    const reply = setupReply({ request: item.request, clarify: item.clarify, buildOptions: buildQ ? options : null, build, live, path, others, answers });
    setSent(reply.note);
    if (reply.opts) onSend?.(item.request, reply.opts);
  };
  return (
    <div className="kit-panel space-y-3 px-3 py-2 text-sm">
      {buildQ && (
        <div className="space-y-2">
          <div>{buildQ.question} StreamHub remembers it for this project.</div>
          <div className="grid gap-1.5 sm:grid-cols-3">
            {options.map((o) => (
              <OptionButton key={o.value} on={build === o.value} onPick={() => setBuild(o.value as BuildForm)} option={o} />
            ))}
          </div>
          {item.live && <LiveDataField live={live} path={path} setLive={setLive} setPath={setPath} />}
        </div>
      )}
      {others.map((q) => (
        <SetupQuestion key={q.id} onPick={(o) => pick(q, o)} q={q} value={answers[q.id] || ""} />
      ))}
      {/* Held like the run approval: the same button, size and fill, so nothing starts on a stray click. */}
      <div className="flex flex-wrap items-center gap-2">
        <HoldButton
          className="h-10 min-w-44"
          disabled={!onSend || (buildQ && live && !path.trim())}
          holdDuration={1200}
          holdingLabel="Keep holding..."
          icon={<Hammer className="h-4 w-4" />}
          label={holdsRequest(answers) ? "Hold to confirm" : "Hold to start building"}
          onHoldComplete={send}
          variant="grey"
        />
      </div>
    </div>
  );
}

type SaveBody = { build?: BuildForm | ""; liveSource?: string; forget?: string };
type Save = (b: SaveBody, done: string) => Promise<void>;

/** The open project's setup, loaded per project, and a save that reports what it did. */
function useProjectSetup(projectPath: string) {
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
  const save: Save = async (b, done) => {
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
  return { setup, path, setPath, note, busy, save };
}

/** How pages are built: the three forms, the saved one marked. */
function BuildFormSection({ build, busy, save }: { build: ProjectSetup["build"]; busy: boolean; save: Save }) {
  return (
    <div className="space-y-1">
      <div className="text-muted-foreground">How pages are built (Copilot gets this with every task)</div>
      <div className="grid gap-1">
        {BUILD_FORMS.map((f) => (
          <button aria-pressed={build === f.value} className={choiceClass(build === f.value)} disabled={busy} key={f.value} onClick={() => void save({ build: f.value }, `Saved: ${f.label}.`)} title={f.help} type="button">
            {f.label}
          </button>
        ))}
      </div>
      {!build && <div className="text-muted-foreground">Not chosen yet: StreamHub asks at the first request that builds a page.</div>}
    </div>
  );
}

/** The live data file outside the project: its path, Use this file, Stop following, and where it is copied. */
function LiveFileSection({ live, path, setPath, busy, save }: { live: ProjectSetup["live"]; path: string; setPath: (p: string) => void; busy: boolean; save: Save }) {
  return (
    <div className="space-y-1">
      <div className="text-muted-foreground">Live data file outside the project</div>
      <input aria-label="Full path of the live data file" className={inputClass} disabled={busy} onChange={(e) => setPath(e.target.value)} placeholder={PATH_HINT} value={path} />
      <div className="flex gap-1.5">
        <button className={cn(buttonClass, "bg-(--kit-surface-2)")} disabled={busy || !path.trim() || path.trim() === live?.path} onClick={() => void save({ liveSource: path.trim() }, "Saved: StreamHub copies the file in when it changes.")} type="button">
          Use this file
        </button>
        {live && (
          <button className={buttonClass} disabled={busy} onClick={() => void save({ liveSource: "" }, "The live data file is no longer followed; the last copy stays.")} type="button">
            Stop following
          </button>
        )}
      </div>
      {live ? (
        <div className="text-muted-foreground">
          Copied to {live.copy}
          {live.found ? "" : " (the file is not found right now: is its folder still synced?)"}.
        </div>
      ) : (
        <div className="text-muted-foreground">{LIVE_HELP}</div>
      )}
    </div>
  );
}

/** The other questions answered for the project, each with Forget. */
function SavedAnswers({ answers, busy, save }: { answers: SetupAnswer[]; busy: boolean; save: Save }) {
  if (answers.length === 0) return null;
  return (
    <div className="space-y-1">
      <div className="text-muted-foreground">Choices made for this project (asked when a request needed them; Copilot gets them with every task)</div>
      {answers.map((a) => (
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
  );
}

/** Files tab > Project setup: the build form and the live data file of the open project, to change later. */
export function ProjectSetupPanel({ projectPath }: { projectPath: string }) {
  const { setup, path, setPath, note, busy, save } = useProjectSetup(projectPath);
  if (!setup) return <p className="text-muted-foreground text-xs">No project open.</p>;
  return (
    <div className="space-y-2 text-xs">
      <BuildFormSection build={setup.build} busy={busy} save={save} />
      <LiveFileSection busy={busy} live={setup.live} path={path} save={save} setPath={setPath} />
      <SavedAnswers answers={setup.answers ?? []} busy={busy} save={save} />
      {setup.answers?.some((a) => a.id === "audience" && a.value === "sharepoint") && <SharePointSection projectPath={projectPath} />}
      <DatabasesSection projectPath={projectPath} />
      <WebAllowSection projectPath={projectPath} />
      {note && <div className="text-muted-foreground">{note}</div>}
    </div>
  );
}
