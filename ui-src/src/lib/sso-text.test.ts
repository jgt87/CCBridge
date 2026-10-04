import { describe, expect, it } from "vitest";
import type { SsoStatus } from "./api";
import { copilotText, ssoStateText } from "./sso-text";

const base: SsoStatus = { workAccount: true, profileSso: "on", copilot: "chat" };

describe("sign-in texts", () => {
  it("say what each switch state means", () => {
    expect(ssoStateText(null)).toBe("Checking...");
    expect(ssoStateText(base)).toMatch(/^On /);
    expect(ssoStateText({ ...base, profileSso: "managed" })).toMatch(/organisation/);
    expect(ssoStateText({ ...base, workAccount: false, profileSso: "unavailable" })).toMatch(/Stay signed in/);
  });
  it("never name the company, only the account kind", () => {
    for (const p of ["on", "off", "managed", "not-found", "unavailable", "edge-not-running", "unknown"] as const) {
      expect(ssoStateText({ ...base, profileSso: p })).not.toMatch(/work pc|laptop/i);
    }
  });
  it("describe the Copilot tab", () => {
    expect(copilotText("chat")).toBe("signed in");
    expect(copilotText("sign-in page")).toBe("on a sign-in page");
    expect(copilotText(undefined)).toBe("-");
  });
});
