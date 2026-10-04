import type { SsoStatus } from "./api";

/** Settings > Sign-in: what the switch state means, in words. */
export function ssoStateText(s: SsoStatus | null): string {
  if (!s) return "Checking...";
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
export function copilotText(c: SsoStatus["copilot"] | undefined): string {
  if (c === "chat") return "signed in";
  if (c === "sign-in page") return "on a sign-in page";
  if (c === "no tab") return "no Copilot tab open";
  if (c === "edge not running") return "Edge not running";
  return "-";
}
