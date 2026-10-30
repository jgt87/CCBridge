import { useEffect, useState } from "react";
import { api, type SsoStatus } from "@/lib/api";
import { cachedSso, loadSso, rememberSso } from "@/lib/settings-cache";
import { afterSetupStatus, ssoStateText, ssoStatusRows, switchNote } from "@/lib/sso-text";
import { Segmented, SettingLine, smallButtonClass } from "./settings-ui";

/** The sign-in status, kept in the settings cache, and the steps that change it (one at a time, with a busy label). */
function useSso() {
  // Shown at once from the background load; checked again quietly when Settings opens.
  const [status, setStatusState] = useState<SsoStatus | null>(cachedSso());
  const setStatus = (next: SsoStatus | null | ((s: SsoStatus | null) => SsoStatus | null)) =>
    setStatusState((cur) => {
      const v = typeof next === "function" ? next(cur) : next;
      rememberSso(v);
      return v;
    });
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
    if (cachedSso()) loadSso().then(setStatusState, () => {});
    else check();
    // biome-ignore lint/correctness/useExhaustiveDependencies: checked once when Settings opens
  }, []);

  // On: StreamHub's Edge profile (and Edge's own switch, when it offers one and it is off).
  // Off: Copilot in a private session, where the Windows account is not used. From the next start.
  const switchTo = (on: boolean) =>
    run(on ? "Turning on..." : "Turning off...", async () => {
      await api.setSetting("signIn", on ? "single-sign-on" : "private");
      const edge = on && status?.profileSso === "off" ? (await api.setSso(true)).result : "";
      setStatus(await api.ssoStatus());
      setNote(switchNote(on, edge));
    });
  const setup = () =>
    run("Running setup...", async () => {
      const r = await api.ssoSetup();
      setStatus((s) => afterSetupStatus(s, r));
      setNote(`Setup: ${r.result}. Log: ${r.logFile}`);
      if (r.result === "already on") setStatus(await api.ssoStatus());
    });
  const open = () =>
    run("Opening...", async () => {
      await api.openSsoSettings();
      setNote("Edge's profile settings are open in StreamHub's Edge window.");
    });

  return { status, busy, note, error, check, switchTo, setup, open };
}

/** The status list, what the switch state means (or the step running now), the last note and error. */
function SsoNotes({ status, busy, note, error }: { status: SsoStatus | null; busy: string; note: string; error: string }) {
  return (
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
      {error && <div className="kit-error-text">{error}</div>}
    </>
  );
}

/**
 * Settings > Sign-in: single sign-on with the Windows work account in StreamHub's own Edge profile,
 * so Copilot signs in by itself after a restart. No password is stored; Edge policies and the
 * normal Edge profile are not touched.
 */
export function SsoSection() {
  const { status, busy, note, error, check, switchTo, setup, open } = useSso();

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
      notes={<SsoNotes busy={busy} error={error} note={note} status={status} />}
      title="Sign in with your Windows account (single sign-on)"
    />
  );
}
