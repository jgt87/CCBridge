import { describe, expect, it } from "vitest";
import type { Setting } from "@/lib/api";
import { isOnOff, settingControlKind } from "./setting-kind";

const s = (type: Setting["type"], key = "x", options?: string[]) => ({ type, key, options });

describe("settingControlKind", () => {
  it("picks the control for every kind of setting", () => {
    expect(settingControlKind(s("commands"))).toBe("list");
    expect(settingControlKind(s("list"))).toBe("list");
    expect(settingControlKind(s("info"))).toBe("info");
    expect(settingControlKind(s("toggle"))).toBe("switch");
    expect(settingControlKind(s("select", "enforcement", ["light", "standard", "strict"]))).toBe("tiers");
    expect(settingControlKind(s("select", "workIq", ["off", "on"]))).toBe("switch");
    expect(settingControlKind(s("select", "appWindow", ["copilot-tab", "browser"]))).toBe("select");
    expect(settingControlKind(s("number"))).toBe("number");
  });

  it("knows a choice of just on and off", () => {
    expect(isOnOff(["on", "off"])).toBe(true);
    expect(isOnOff(["off", "on", "leave"])).toBe(false);
    expect(isOnOff(undefined)).toBe(false);
  });
});
