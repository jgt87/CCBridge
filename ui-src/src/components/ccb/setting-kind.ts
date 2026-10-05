import type { Setting } from "@/lib/api";

/** A select whose options are exactly on and off (in any order). */
export function isOnOff(options: string[] | undefined): boolean {
  const o = [...(options ?? [])].sort();
  return o.length === 2 && o[0] === "off" && o[1] === "on";
}

/**
 * Which control a setting gets in Settings: a list box (commands, protected paths), a read-only
 * value (info), an on/off switch (toggle, or a select of just on and off), the tier switch
 * (enforcement), a dropdown (other selects) or a number box.
 */
export type SettingControlKind = "list" | "info" | "switch" | "tiers" | "select" | "number";

export function settingControlKind(s: Pick<Setting, "type" | "key" | "options">): SettingControlKind {
  if (s.type === "commands" || s.type === "list") return "list";
  if (s.type === "info") return "info";
  if (s.type === "toggle") return "switch";
  if (s.type !== "select") return "number";
  if (s.key === "enforcement") return "tiers";
  return isOnOff(s.options) ? "switch" : "select";
}
