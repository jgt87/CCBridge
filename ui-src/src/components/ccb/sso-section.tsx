import { useEffect, useState } from "react";
import { api, type SsoStatus } from "@/lib/api";
import { copilotText, ssoStateText } from "@/lib/sso-text";
import { Segmented, SettingLine, smallButtonClass } from "./settings-ui";

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
      if (r.result === "already on") setStatus(await api.ssoStatus());
    });
  const open = () => run("Opening...", async () => {
    await api.openSsoSettings();
    setNote("Edge's profile settings are open in StreamHub's Edge window.");
  });

  const canSwitch = !busy && status !== null && (status.profileSso === "on" || status.profileSso === "off");
  const on = status?.profileSso === "on";

  const accountText = status?.profileAccount === "work" ? "a work account" : status?.profileAccount === "personal" ? "a personal account" : status?.profileAccount === "none" ? "no account" : "unknown";
  return (
    <SettingLine
      below={
        <div className="flex flex-wrap gap-1.5">
          <button className={smallButtonClass} disabled={!!busy} onClick={check} type="button">
            Check again
          </button>
          <button className={smallButtonClass} disabled={!!busy || !status?.workAccount} onClick={setup} title="Runs the full check, turns single sign-on on and writes a log to C:\temp" type="button">
            Run setup
          </button>
          <button className={smallButtonClass} disabled={!!busy} onClick={open} title="edge://settings/profiles/multiProfileSettings in StreamHub's Edge window" type="button">
            Open Edge's profile settings
          </button>
        </div>
      }
      control={
        <Segmented
          disabled={!canSwitch}
          label="Single sign-on"
          onChange={(o) => switchTo(o === "on")}
          options={[
            { id: "on", label: "On" },
            { id: "off", label: "Off" },
          ]}
          value={canSwitch ? (on ? "on" : "off") : null}
        />
      }
      help="Copilot signs in by itself after a restart, with the work account Windows already holds. No password is stored, and only StreamHub's own Edge profile is changed."
      notes={
        <>
          <div className="mt-1 text-muted-foreground text-xs">{busy || ssoStateText(status)}</div>
          {status && (
            <div className="text-muted-foreground text-xs">
              Work account on this PC: {status.workAccount ? "yes" : "no"}. Edge profile signed in with: {accountText}. Copilot: {copilotText(status.copilot)}.
            </div>
          )}
          {note && <div className="text-muted-foreground text-xs">{note}</div>}
          {error && <div className="text-rose-500 text-xs">{error}</div>}
        </>
      }
      title="Sign in with your Windows account (single sign-on)"
    />
  );
}