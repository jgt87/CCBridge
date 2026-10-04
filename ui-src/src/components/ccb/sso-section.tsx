import { useEffect, useState } from "react";
import { api, type SsoStatus } from "@/lib/api";
import { ssoStateText, ssoStatusRows } from "@/lib/sso-text";
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

  // On: StreamHub's Edge profile (and Edge's own switch, when it offers one and it is off).
  // Off: Copilot in a private session, where the Windows account is not used. From the next start.
  const switchTo = (on: boolean) =>
    run(on ? "Turning on..." : "Turning off...", async () => {
      await api.setSetting("signIn", on ? "single-sign-on" : "private");
      let edge = "";
      if (on && status?.profileSso === "off") edge = (await api.setSso(true)).result;
      setStatus(await api.ssoStatus());
      setNote(
        on
          ? `Single sign-on on${edge ? ` (Edge's switch: ${edge})` : ""}. Applies at the next StreamHub start.`
          : "Single sign-on off: from the next StreamHub start, Copilot opens in a private session where you sign in yourself."
      );
    });  const setup = () =>
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

  // The switch works whenever there is something to sign in with, and always to come back from a private session.
  const canSwitch = !busy && status !== null && (status.workAccount || status.signIn === "private");
  const on = status?.signIn !== "private";

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
          // Turned on by Edge itself (or by the work account): shown as on, but StreamHub cannot change it.
          value={status ? (on ? "on" : "off") : null}
        />
      }
      help="Copilot signs in by itself after a restart, with the work account Windows already holds. No password is stored, and only StreamHub's own Edge profile is changed."
      notes={
        <>
          {status && !busy && (
            <ul className="mt-1.5 space-y-0.5 text-xs">
              {ssoStatusRows(status).map((r) => (
                <li className="flex gap-1.5" key={r.label}>
                  <span className="text-muted-foreground">&bull;</span>
                  <span className="text-muted-foreground">{r.label}:</span>
                  <span>{r.value}</span>
                </li>
              ))}
            </ul>
          )}
          <div className="mt-1 text-muted-foreground text-xs">{busy || ssoStateText(status)}</div>
          {note && <div className="text-muted-foreground text-xs">{note}</div>}
          {error && <div className="text-rose-500 text-xs">{error}</div>}
        </>
      }
      title="Sign in with your Windows account (single sign-on)"
    />
  );
}