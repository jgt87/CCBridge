/** The group shown at the top of the list, and the first time Settings opens. */
export const FIRST_SECTION = "App";
/** Sections that are not app settings groups, right after it. */
export const FIXED_SECTIONS = ["This browser", "This computer", "Sign-in"];

/** The app settings per group, in the order the groups first appear; Sign-in settings have their own section. */
export function settingGroups<T extends { group: string }>(settings: T[]): [string, T[]][] {
  const m = new Map<string, T[]>();
  for (const s of settings) if (s.group !== "Sign-in") m.set(s.group, [...(m.get(s.group) ?? []), s]);
  return [...m.entries()];
}

/** App first, then this browser, this computer and sign-in, then the other groups. */
export function settingSections(groupNames: string[]): string[] {
  const first = groupNames.filter((g) => g === FIRST_SECTION);
  return [...first, ...FIXED_SECTIONS, ...groupNames.filter((g) => g !== FIRST_SECTION)];
}

/** The chosen section, or the first one when it is no longer there. */
export function currentSection(sections: string[], chosen: string): string {
  return sections.includes(chosen) ? chosen : sections[0];
}
