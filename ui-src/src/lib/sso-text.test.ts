import { describe, expect, it } from "vitest";
import type { SsoStatus } from "./api";
import { copilotText, ssoStateText, ssoStatusRows } from "./sso-text";

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
    expect(copilotText("sign-in page")).toBe("on Microsoft's sign-in page");
    expect(copilotText("other page", "sso.example.org")).toMatch(/^on sso.example.org: probably your organisation/);
    expect(copilotText(undefined)).toBe("-");
  });
});

describe("sign-in status list", () => {
  it("gives the four rows in order, in words", () => {
    const rows = ssoStatusRows({ workAccount: true, profileSso: "on-auto", profileAccount: "work", copilot: "chat" });
    expect(rows.map((r) => `${r.label}: ${r.value}`)).toEqual([
      "Single sign-on: On, turned on by Edge itself",
      "Work account on this PC: yes",
      "Edge profile: signed in with a work account",
      "Copilot: signed in",
      "Copilot session: StreamHub's Edge profile",
    ]);
    expect(ssoStatusRows({ workAccount: false, profileSso: "unavailable", copilot: "no tab" })[2].value).toBe("unknown");
  });
});

describe("single sign-on off (private session)", () => {
  it("says off and how Copilot signs in then", () => {
    const s = { workAccount: true, profileSso: "on-auto", copilot: "chat", signIn: "private" } as const;
    expect(ssoStatusRows(s)[0].value).toBe("Off (private session)");
    expect(ssoStatusRows(s)[4].value).toBe("private, you sign in yourself");
    expect(ssoStateText(s)).toMatch(/^Off: Copilot opens in a private session/);
  });
});
