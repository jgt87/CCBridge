import { describe, expect, it } from "vitest";
import { eventDate, formatDuration, rowTime, timeDividers } from "./row-time";

const now = new Date(2026, 9, 19, 15, 30, 0);

describe("rowTime", () => {
  it("shows HH:mm for today, from the ISO stamp or the time text", () => {
    expect(rowTime("12:45:01", "2026-10-19T12:45:01", undefined, now)?.label).toBe("12:45");
    expect(rowTime("09:05:30", undefined, undefined, now)?.label).toBe("09:05");
    expect(rowTime("12:45:01", "2026-10-19T12:45:01", undefined, now)?.title).toMatch(/12:45:01/);
  });
  it("puts the day before the time for an earlier day (restored history)", () => {
    const r = rowTime("2026-10-17 08:10", undefined, undefined, now);
    expect(r?.label).toMatch(/17/);
    expect(r?.label).toMatch(/08:10$/);
    expect(eventDate("2026-10-17 08:10", undefined, now)?.getDate()).toBe(17);
  });
  it("says how long a finished action took", () => {
    const r = rowTime("12:00:00", "2026-10-19T12:00:00", "2026-10-19T12:02:05", now);
    expect(r?.took).toBe("2 min 5 s");
    expect(r?.title).toMatch(/took 2 min 5 s/);
    expect(rowTime("12:00:00", "2026-10-19T12:00:00", undefined, now)?.took).toBeUndefined();
  });
  it("keeps an unreadable time as it is, and nothing for no time", () => {
    expect(rowTime("soon", undefined, undefined, now)?.label).toBe("soon");
    expect(rowTime(undefined, undefined, undefined, now)).toBeNull();
  });
  it("writes durations short", () => {
    expect(formatDuration(8_000)).toBe("8 s");
    expect(formatDuration(120_000)).toBe("2 min");
    expect(formatDuration(3_840_000)).toBe("1 h 4 min");
  });
});

describe("timeDividers", () => {
  it("puts a time before the first item of each minute, not before every item", () => {
    const now = new Date(2026, 9, 21, 12, 0, 0);
    const at = (h: number, m: number, s = 0) => new Date(2026, 9, 21, h, m, s).toISOString();
    const out = timeDividers([{ at: at(9, 5, 1) }, { at: at(9, 5, 40) }, {}, { at: at(9, 7) }, { at: at(9, 7, 30) }], now);
    expect(out.map((t) => t?.label ?? null)).toEqual(["09:05", null, null, "09:07", null]);
  });
  it("shows the day for an earlier day, and again when the day changes", () => {
    const now = new Date(2026, 9, 21, 12, 0, 0);
    const out = timeDividers([{ at: new Date(2026, 9, 20, 23, 26).toISOString() }, { at: new Date(2026, 9, 21, 8, 1).toISOString() }], now);
    expect(out[0]?.label).toMatch(/20.*23:26/);
    expect(out[1]?.label).toBe("08:01");
  });
});
