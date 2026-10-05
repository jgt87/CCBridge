import { useEffect, useState } from "react";
import { api, type ToolItem } from "@/lib/api";
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
      {error && <p className="text-rose-500 dark:text-rose-400 text-xs">{error}</p>}
    </>
  );
}
