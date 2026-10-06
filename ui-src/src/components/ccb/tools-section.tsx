import { useEffect, useState } from "react";
import { api, type PackageItem, type ToolItem } from "@/lib/api";
import { cachedTools, loadTools } from "@/lib/settings-cache";
import { SettingLine, smallButtonClass } from "./settings-ui";

/**
 * Settings > This computer: optional tools (Python, pytest, Node.js, .NET SDK, Git). Each can be
 * installed or updated on request, for this user only and without admin rights; where the
 * computer's rules block it, the tool stays informational and StreamHub works without it.
 */
export function ToolsSection() {
  const [tools, setTools] = useState<ToolItem[] | null>(cachedTools());
  const [error, setError] = useState("");
  const running = (tools ?? []).some((t) => t.install?.state === "running");

  useEffect(() => {
    loadTools().then(setTools, (e) => setError((e as Error).message));
  }, []);
  // While an install runs: look again every 3 seconds.
  useEffect(() => {
    if (!running) return;
    const t = window.setInterval(() => loadTools().then(setTools, () => {}), 3000);
    return () => window.clearInterval(t);
  }, [running]);

  const install = async (name: string) => {
    setError("");
    try {
      await api.installTool(name);
      setTools(await loadTools());
    } catch (e) {
      setError((e as Error).message);
    }
  };

  if (!tools) return <p className="py-2 text-muted-foreground text-xs">{error || "Checking this computer..."}</p>;
  return (
    <>
      {tools.map((t) => {
        const busy = t.install?.state === "running";
        const pending = t.install?.state === "pending";
        const label = t.update && t.latest ? `Update to ${t.latest}` : t.status === "WARN" ? "Update for me" : "Install for me";
        return (
          <SettingLine
            control={
              t.canInstall ? (
                <button className={smallButtonClass} disabled={busy || pending} onClick={() => install(t.name)} title={pending ? "The tool is in use now; the update runs the next time StreamHub starts." : "For your user only, without admin rights. Installing accepts the tool's own licence."} type="button">
                  {busy ? "Installing..." : pending ? "Updates at next start" : label}
                </button>
              ) : (
                <span className="text-muted-foreground text-xs">installed</span>
              )
            }
            help={`${t.detail}${t.update && t.latest && t.canInstall ? ` (newer: ${t.latest})` : ""}${t.hint && (t.status !== "OK" || t.update) ? `. ${t.hint}` : ""}`}
            key={t.name}
            notes={t.install && t.install.state !== "running" ? <div className="text-muted-foreground text-xs">{t.install.message}</div> : null}
            title={t.label}
          />
        );
      })}
      <ProjectPackages />
      {error && <p className="text-rose-500 dark:text-rose-400 text-xs">{error}</p>}
    </>
  );
}

/** The open project's npm packages: what package.json lists and node_modules does not have, and npm install. */
function ProjectPackages() {
  const [state, setState] = useState<{ items: PackageItem[]; npm: boolean } | null>(null);
  const [note, setNote] = useState("");
  useEffect(() => {
    api.packages().then(setState, () => setState({ items: [], npm: false }));
  }, []);
  const missing = (state?.items ?? []).filter((p) => p.missing.length);
  const run = async () => {
    setNote("");
    try {
      await api.installPackages();
      setNote("npm install started: the chat shows its progress and output.");
    } catch (e) {
      setNote((e as Error).message);
    }
  };
  const where = (p: PackageItem) => (p.folder ? `${p.folder}/` : "the project root");
  const help = !state
    ? "Checking the open project..."
    : !state.items.length
      ? "The open project has no package.json (plain pages need no packages)."
      : missing.length
        ? missing.map((p) => `${p.missing.length} of ${p.total} not installed in ${where(p)}`).join("; ")
        : `All packages are installed (${state.items.map(where).join(", ")}).`;
  return (
    <SettingLine
      control={
        <button className={smallButtonClass} disabled={!state?.items.length || !state.npm} onClick={run} title={state && !state.npm ? "npm is not installed: install Node.js above first." : "Downloads the packages from npm's registry and runs their install steps."} type="button">
          Run npm install
        </button>
      }
      help={`${help}${state && state.items.length && !state.npm ? ". npm is not installed: install Node.js above first" : ""}`}
      notes={note ? <div className="text-muted-foreground text-xs">{note}</div> : null}
      title="Project packages (npm install)"
    />
  );
}
