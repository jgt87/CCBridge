import { describe, expect, it } from "vitest";
import { pendingChatText, pendingSince } from "./pending-chat";

describe("pending chat bar", () => {
  it("takes the local time from the server's ISO time, without converting time zones", () => {
    expect(pendingSince("2026-11-17T10:42:05")).toBe("10:42");
    expect(pendingSince("2026-11-17T09:05:00+01:00")).toBe("09:05");
  });
  it("leaves the time out when it cannot be read", () => {
    expect(pendingSince("")).toBe("");
    expect(pendingSince(null)).toBe("");
    expect(pendingChatText("yesterday")).toBe("Copilot was still working when StreamHub stopped waiting. It was left running, so its work is not lost.");
  });
  it("says when the request was sent and that the work goes on", () => {
    expect(pendingChatText("2026-11-17T10:42:05")).toBe(
      "Copilot was still working when StreamHub stopped waiting (request sent at 10:42). It was left running, so its work is not lost.",
    );
  });
});
