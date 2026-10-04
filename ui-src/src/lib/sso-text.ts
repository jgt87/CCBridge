import type { SsoStatus } from "./api";

/** Settings > Sign-in: what the switch state means, in words. */
export function ssoStateText(s: SsoStatus | null): string {
  if (!s) return "Checking...";
  if (s.signIn === "private")
    return "Off: Copilot opens in a private session, where you sign in yourself once per Edge start; your Windows account is not used. Turn it on to sign in with your Windows account again. Applies at the next StreamHub start.";
  switch (s.profileSso) {
    case "on":
      return "On in StreamHub's Edge profile.";
    case "off":
      return "Off in StreamHub's Edge profile.";
    case "on-auto":
      return "On: Edge turned single sign-on for work sites on by itself for StreamHub's profile, so there is nothing to change. If Copilot still asks after a restart, sign in once and choose \"Stay signed in\".";
    case "signed-in-work":
      return "Not needed: StreamHub's Edge profile is signed in with your work account, so work sites sign in with it already. If Copilot still asks after a restart, sign in once and choose \"Stay signed in\".";
    case "managed":
      return "Set by your organisation (policy); it cannot be changed here.";
    case "not-found":
      return "Edge does not offer the switch for this profile. Open Edge's profile settings to look, or sign in once and choose \"Stay signed in\".";
    case "unavailable":
      return "No work account on this PC, so there is nothing to sign in with. Sign in once in StreamHub's Edge window and choose \"Stay signed in\".";
    case "edge-not-running":
      return "StreamHub's Edge is not running.";
    default:
      return "Unknown.";
  }
}

/** Where the Copilot tab is, in words. */
export function copilotText(c: SsoStatus["copilot"] | undefined, host?: string | null): string {
  if (c === "chat") return "signed in";
  if (c === "sign-in page") return "on Microsoft's sign-in page";
  if (c === "other page") return `on ${host || "another site"}: probably your organisation's sign-in page, so single sign-on did not sign in`;
  if (c === "no tab") return "no Copilot tab open";
  if (c === "edge not running") return "Edge not running";
  return "-";
}

/** The switch state in a few words, for the status list. */
export function ssoShortText(s: SsoStatus): string {
  if (s.signIn === "private") return "Off (private session)";
  switch (s.profileSso) {
    case "on":
      return "On";
    case "on-auto":
      return "On, turned on by Edge itself";
    case "signed-in-work":
      return "On, through the work account";
    case "off":
      return "Off";
    case "managed":
      return "Set by your organisation";
    case "not-found":
      return "Not offered by Edge";
    case "unavailable":
      return "Not available";
    case "edge-not-running":
      return "Edge is not running";
    default:
      return "Unknown";
  }
}

/** Which account StreamHub's Edge profile uses, in words. */
export function accountText(a: SsoStatus["profileAccount"]): string {
  if (a === "work") return "signed in with a work account";
  if (a === "personal") return "signed in with a personal account";
  if (a === "none") return "not signed in";
  return "unknown";
}

/** Settings > Sign-in: the status as label/value rows. */
export function ssoStatusRows(s: SsoStatus): { label: string; value: string }[] {
  return [
    { label: "Single sign-on", value: ssoShortText(s) },
    { label: "Work account on this PC", value: s.workAccount ? "yes" : "no" },
    { label: "Edge profile", value: accountText(s.profileAccount) },
    { label: "Copilot", value: copilotText(s.copilot, s.copilotHost) },
    { label: "Copilot session", value: s.signIn === "private" ? "private, you sign in yourself" : "StreamHub's Edge profile" },
  ];
}
