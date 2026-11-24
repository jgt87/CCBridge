// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { notifyEnabled, setNotifyEnabled } from "./notify";

afterEach(() => {
  vi.unstubAllGlobals();
  localStorage.clear();
});

describe("notifications switch", () => {
  it("does not turn notifications on when the person switched them off while the browser asked", async () => {
    let answer: (p: NotificationPermission) => void = () => {};
    const fake = { permission: "default" as NotificationPermission, requestPermission: () => new Promise<NotificationPermission>((r) => (answer = r)) };
    vi.stubGlobal("Notification", fake);
    const turningOn = setNotifyEnabled(true);
    await setNotifyEnabled(false);
    fake.permission = "granted";
    answer("granted");
    expect(await turningOn).toBe(false);
    expect(localStorage.getItem("ccb.notify")).toBe("0");
    expect(notifyEnabled()).toBe(false);
  });

  it("turns them on once the browser allows it", async () => {
    vi.stubGlobal("Notification", { permission: "granted", requestPermission: () => Promise.resolve("granted") });
    expect(await setNotifyEnabled(true)).toBe(true);
    expect(notifyEnabled()).toBe(true);
  });
});
