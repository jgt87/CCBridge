import { AlertTriangle, ClipboardList, FolderOpen, Menu as MenuIcon, MessageSquarePlus, PanelLeftOpen, Settings, X } from "lucide-react";
import CommandButton from "@/components/kokonutui/command-button";
import Loader from "@/components/kokonutui/loader";
import { CopilotStatus } from "@/components/ccb/copilot-status";
import { LimitationsNote } from "@/components/ccb/limitations-note";
import type { Notice } from "@/components/ccb/command-palette";
import { type AppState, api } from "@/lib/api";
import { openExternal } from "@/lib/links";
import { responseChoices } from "@/lib/response-modes";

export type AgentChoice = "auto" | "copilot" | "researcher" | "analyst";

/** The changelog on GitHub, always the current one on main (newer entries than this build included). */
const changelogUrl = () => "https://github.com/jgt87/CCBridge/blob/main/CHANGELOG.md";

export function AppHeader({ state, showDrawerButton, onOpenDrawer, onSwitchProject, onSettings, onMenu }: {
  state: AppState;
  showDrawerButton: boolean;
  onOpenDrawer: () => void;
  onSwitchProject: () => void;
  onSettings: () => void;
  onMenu: () => void;
}) {
  return (
    <header className="flex h-14 shrink-0 items-center gap-3 border-(--kit-border) border-b px-4">
      {showDrawerButton && (
        <button
          aria-label="Open side panel"
          className="kit-btn kit-btn--ghost kit-btn--icon -ml-1.5 h-8 w-8 text-muted-foreground hover:text-foreground"
          onClick={onOpenDrawer}
          title="Open side panel (the window is too narrow to show it beside the chat)"
          type="button"
        >
          <PanelLeftOpen className="h-4 w-4" />
        </button>
      )}
      <div className="flex items-center gap-2 font-semibold tracking-tight">
        <span className="grid h-7 w-7 place-items-center rounded-lg bg-foreground text-background text-xs">SH</span>
        <span>StreamHub <span className="ml-0.5 font-normal text-muted-foreground">by JGT</span></span>
      </div>
      {state.project && (
        <button
          className="flex min-w-0 items-center gap-1.5 rounded-lg px-2 py-1 text-muted-foreground text-sm hover:bg-(--kit-surface-2) hover:text-foreground"
          onClick={onSwitchProject}
          title={`${state.project.name}\n${state.project.path}\nClick to open or create another project`}
          type="button"
        >
          <FolderOpen className="h-4 w-4" />
          <span className="truncate">Switch project</span>
        </button>
      )}
      <div className="flex-1" />
      <CopilotStatus copilot={state.copilot} message={state.copilotMessage} />
      <button
        aria-label="Settings"
        className="kit-btn kit-btn--ghost kit-btn--icon h-8 w-8 text-muted-foreground hover:text-foreground"
        onClick={onSettings}
        title="Settings"
        type="button"
      >
        <Settings className="h-4 w-4" />
      </button>
      <CommandButton className="h-8" icon={MenuIcon} onClick={onMenu} title="Commands and files (Ctrl+K)">
        Menu
      </CommandButton>
    </header>
  );
}

export function NoticeBar({ notice, onDismiss }: { notice: Notice; onDismiss: () => void }) {
  return (
    <div className="flex items-center justify-between gap-3 bg-(--kit-surface-2) px-4 py-2 text-sm">
      <span className="truncate">{notice.text}</span>
      <span className="flex shrink-0 items-center gap-3">
        {notice.path && (
          <button className="kit-link" onClick={() => api.showDiagnostics(notice.path!)} type="button">
            Show in folder
          </button>
        )}
        <button aria-label="Dismiss" className="kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm" title="Dismiss" onClick={onDismiss} type="button">
          <X className="h-4 w-4" />
        </button>
      </span>
    </div>
  );
}

export function ErrorBar({ error, onDismiss }: { error: string; onDismiss: () => void }) {
  return (
    <div className="kit-notice kit-notice--error items-center justify-between rounded-none border-x-0 border-t-0 px-4 py-2 text-(--kit-error) text-sm" role="alert">
      {error}
      <button aria-label="Dismiss the error" className="kit-btn kit-btn--ghost kit-btn--icon kit-btn--sm text-(--kit-error)" title="Dismiss" onClick={onDismiss} type="button">
        <X className="h-4 w-4" />
      </button>
    </div>
  );
}

/** The installed release and the commit it was built from, under the side panel. */
export function VersionLine({ state }: { state: AppState }) {
  if (!state.version) return null;
  return (
    <div
      className="flex shrink-0 items-center justify-center gap-2 px-1 pt-2 text-muted-foreground text-xs"
      title="Installed StreamHub release and the commit it was built from; with automatic updates on, a new release installs when a new instance of the app starts (or run update.cmd)"
    >
      <span>StreamHub {state.release || state.version}</span>
      {state.commit && (
        <>
          <span aria-hidden className="h-3 w-px bg-(--kit-border-strong)" />
          <a
            className="font-mono underline-offset-2 hover:text-foreground hover:underline"
            href={changelogUrl()}
            onClick={openExternal}
            rel="noopener noreferrer"
            target="_blank"
            title="What changed: the changelog on GitHub (this build's commit shown)"
          >
            {state.commit}
          </a>
        </>
      )}
    </div>
  );
}

export function InstallProblem({ problem }: { problem: string }) {
  return (
    <div className="flex items-start gap-2 border-(--kit-border) border-b bg-(--kit-surface-2) px-4 py-2 text-xs" role="alert">
      <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
      <span>
        {problem} Close StreamHub and run <span className="font-mono">update.cmd</span> in its folder to install the files again
        (or run <span className="font-mono">install.ps1</span> from a fresh download). Things may not work as expected until then.
      </span>
    </div>
  );
}

/** The chat before its first message: connecting, or what to do. */
export function ChatEmpty({ state }: { state: AppState }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-6 px-6 py-16 text-center">
      {state.copilot === "connecting" ? (
        <Loader size="sm" subtitle={state.copilotMessage || "Opening Copilot in Edge"} title="Connecting to Copilot" />
      ) : (
        <>
          <ClipboardList className="h-10 w-10 text-muted-foreground/50" />
          <div className="max-w-md space-y-1">
            <p className="font-medium">What should we build in {state.project?.name}?</p>
            <p className="text-muted-foreground text-sm">
              Describe the change. Copilot reads the project, proposes edits and commands, and StreamHub applies them after your approval.
              Type <span className="font-mono">@</span> or use the @ button to attach files.
            </p>
          </div>
          {state.copilot === "ready" && <LimitationsNote />}
        </>
      )}
    </div>
  );
}

/** Left of the message box header: who answers, Copilot's response mode, and the queued note. */
export function PromptHeaderLeft({ state, agent, onAgent, queuedNote, fail }: { state: AppState; agent: AgentChoice; onAgent: (v: AgentChoice) => void; queuedNote: boolean; fail: (message: string) => void }) {
  return (
    <>
      <select
        aria-label="Who answers"
        className="kit-btn kit-btn--sm shrink-0"
        onChange={(e) => onAgent(e.target.value as AgentChoice)}
        title="Who answers the next message: Copilot (with StreamHub's instructions), or one of Copilot's agents. Researcher researches a question for several minutes (web and your Microsoft 365 data) and may first ask about its plan; Analyst analyses data, for example an attached file, and can make charts. An agent gets your message as typed, in a new Copilot chat. Auto: StreamHub picks by fixed words - Analyst when you ask for analysis, a chart or a trend of a data file (csv, xlsx, json) you attach or name; Researcher when you ask to research, investigate, compare competitors or the market, or for sources; Copilot itself for everything else, including all work on code."
        value={agent}
      >
        <option value="auto">Agent: Auto</option>
        <option value="copilot">Agent: none (Copilot)</option>
        <option value="researcher">Agent: Researcher</option>
        <option value="analyst">Agent: Analyst</option>
      </select>
      <select
        className="kit-btn kit-btn--sm shrink-0"
        onChange={(e) => api.setResponseMode(e.target.value).catch((err) => fail((err as Error).message))}
        title={`Copilot's response mode: Auto, Quick response, Think deeper, or any other option Copilot's own picker offers here (read when StreamHub connects, such as Advanced reasoning or a model)${state.responseModeActual ? `; the page shows: ${state.responseModeActual}` : ""}`}
        value={state.responseMode ?? "leave"}
      >
        {responseChoices(state.responseOptions, state.responseMode).map((c) => (
          <option key={c.value} title={c.hint} value={c.value}>
            {c.label}
          </option>
        ))}
      </select>
      {queuedNote && (
        <span className="truncate font-medium" title="Waiting tasks run while StreamHub is open; if you close it, they continue at the next start.">
          Queued: runs after the current task, while StreamHub stays open.
        </span>
      )}
    </>
  );
}

const clock = (iso: string) => new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

/** Copilot's daily credits, shown only when 10 or fewer are left. */
function CreditsLeft({ credits }: { credits: AppState["credits"] }) {
  if (!credits || credits.remaining > 10) return null;
  const out = credits.remaining === 0;
  return (
    <span className={out ? "text-(--kit-error)" : "text-muted-foreground"} title={`Copilot daily credits; they reset at ${clock(credits.resetAt)}`}>
      {out ? `Out of Copilot credits until ${clock(credits.resetAt)}` : `${credits.remaining} credits left`}
    </span>
  );
}

const workIqLabel = (v: AppState["workIq"]) => (v === "on" ? "on" : v === "off" ? "off" : "(as set in Copilot)");

/** Right of the message box header: Work IQ, credits, messages used, New chat. */
export function PromptHeaderRight({ state, newChatPending, onNewChat }: { state: AppState; newChatPending: boolean; onNewChat: () => void }) {
  const workIqOn = state.workIq === "on";
  return (
    <span className="flex items-center gap-2">
      {state.workIqAvailable && (
        <button
          aria-pressed={workIqOn}
          className={workIqOn ? "kit-btn kit-btn--primary kit-btn--sm h-7 min-h-0 px-2 font-medium" : "kit-btn kit-btn--sm h-7 min-h-0 px-2"}
          onClick={() => api.setWorkIq(workIqOn ? "off" : "on")}
          title="Work IQ lets Copilot use your Microsoft 365 data: Outlook, Teams, calendar, OneDrive and SharePoint"
          type="button"
        >
          Work IQ {workIqLabel(state.workIq)}
        </button>
      )}
      <CreditsLeft credits={state.credits} />
      {state.throttle.max > 0 && (
        <span className="text-muted-foreground" title="Messages used in this Copilot chat; StreamHub starts a new chat with a summary before the limit">
          {state.throttle.used}/{state.throttle.max}
        </span>
      )}
      <button className="kit-btn kit-btn--sm h-7 min-h-0 px-2" disabled={newChatPending} onClick={onNewChat} title="Start a new Copilot conversation (the project stays open)" type="button">
        <MessageSquarePlus className="h-3.5 w-3.5" />
        {newChatPending ? "Starting..." : "New chat"}
      </button>
    </span>
  );
}
