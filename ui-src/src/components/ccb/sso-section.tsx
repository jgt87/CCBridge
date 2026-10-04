import { useEffect, useState } from "react";
import { api, type SsoStatus } from "@/lib/api";
import { copilotText, ssoStateText } from "@/lib/sso-text";
import { cn } from "@/lib/utils";

const button = "rounded-md border border-black/10 px-2 py-1 text-xs hover:bg-black/5 disabled:opacity-40 disabled:hover:bg-transparent dark:border-white/10 dark:hover:bg-white/5";

/**
 * Settings > Sign-in: single sign-on with the Windows work account in StreamHub's own Edge profile,
 * so Copilot signs in by itself after a restart. No password is stored; Edge policies and the
 * normal Edge profile are not touched.
 */
export function SsoSection() {
  const [status, setStatus] = useState<SsoStatus | null>(null);
  const [busy, setBusy] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState("");

  const run = async (label: string, work: () => Promise<void>) => {
    setBusy(label);
    setError("");
    try {
      await work();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy("");
    }
  };
  const check = () => run("Checking...", async () => setStatus(await api.ssoStatus()));
  useEffect(() => {
    check();
    // biome-ignore lint/correctness/useExhaustiveDependencies: checked once when Settings opens
  }, []);

  const switchTo = (on: boolean) =>
    run(on ? "Turning on..." : "Turning off...", async () => {
      const r = await api.setSso(on);
      setStatus(r.status);
      setNote(r.result.startsWith("turned") ? `Single sign-on ${r.result.replace("turned ", "")}. Applies after StreamHub restarts.` : `Not changed: ${r.result}.`);
    });
  const setup = () =>
    run("Running setup...", async () => {
      const r = await api.ssoSetup();
      setStatus((s) => ({ ...(s ?? r.status), ...r.status, profileSso: r.result === "turned on" || r.result === "already on" ? "on" : (s?.profileSso ?? r.status.profileSso) }));
      setNote(`Setup: ${r.result}. Log: ${r.logFile}`);
    });
  const open = () => run("Opening...", async () => {
    await api.openSsoSettings();
    setNote("Edge's profile settings are open in StreamHub's Edge window.");
  });

  const canSwitch = !busy && status !== null && (status.profileSso === "on" || status.profileSso === "off");
  const on = status?.profileSso === "on";

  return (
    <div className="pt-2">
      <div className="mt-1 font-medium text-muted-foreground text-xs uppercase tracking-wide">Sign-in</div>
      <div className="flex items-start gap-3 py-2">
        <div className="min-w-0 flex-1">
          <div className="text-sm">Sign in with your Windows account (single sign-on)</div>
          <div className="text-muted-foreground text-xs">
            Copilot signs in by itself after a restart, with the work account Windows already holds. No password is stored, and only StreamHub's own Edge profile is changed.
          </div>
          <div className="mt-1 text-muted-foreground text-xs">{busy || ssoStateText(status)}</div>
          {status && (
            <div className="text-muted-foreground text-xs">
              Work account on this PC: {status.workAccount ? "yes" : "no"}. Copilot: {copilotText(status.copilot)}.
            </div>
          )}
          {note && <div className="text-muted-foreground text-xs">{note}</div>}
          {error && <div className="text-rose-500 text-xs">{error}</div>}
        </div>
        <div className="flex w-28 shrink-0 rounded-md border border-black/10 p-0.5 dark:border-white/10" role="radiogroup">
          {([true, false] as const).map((o) => (
            <button
              aria-checked={canSwitch ? on === o : false}
              className={cn(
                "flex-1 rounded px-2 py-0.5 text-xs disabled:opacity-40",
                canSwitch && on === o ? "bg-black/10 text-foreground dark:bg-white/15" : "text-muted-foreground hover:text-foreground"
              )}
              disabled={!canSwitch}
              key={String(o)}
              onClick={() => on !== o && switchTo(o)}
              role="radio"
              type="button"
            >
              {o ? "On" : "Off"}
            </button>
          ))}
        </div>
        <span className="w-[4.25rem]" />
      </div>
      <div className="flex flex-wrap gap-1.5 pb-2">
        <button className={button} disabled={!!busy} onClick={check} type="button">
          Check again
        </button>
        <button className={button} disabled={!!busy || !status?.workAccount} onClick={setup} title="Runs the full check, turns single sign-on on and writes a log to C:\temp" type="button">
          Run setup
        </button>
        <button className={button} disabled={!!busy} onClick={open} title="edge://settings/profiles/multiProfileSettings in StreamHub's Edge window" type="button">
          Open Edge's profile settings
        </button>
      </div>
    </div>
  );
}
