import { afterEach, describe, expect, it, vi } from "vitest";
import { readStored, readStoredJson, writeStored } from "./stored";

const isRecord = (v: unknown): v is Record<string, boolean> => Boolean(v) && typeof v === "object";

function fakeStorage(items: Record<string, string> = {}) {
  return {
    getItem: (k: string) => (k in items ? items[k] : null),
    setItem: (k: string, v: string) => {
      items[k] = v;
    },
    items,
  };
}

afterEach(() => vi.unstubAllGlobals());

describe("stored choices", () => {
  it("reads and writes through localStorage", () => {
    const s = fakeStorage();
    vi.stubGlobal("localStorage", s);
    writeStored("ccb.x", "1");
    expect(readStored("ccb.x")).toBe("1");
    expect(readStored("ccb.missing")).toBeNull();
  });

  it("works without storage: reads give the fallback, writes are skipped", () => {
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
    });
    expect(readStored("ccb.x")).toBeNull();
    expect(() => writeStored("ccb.x", "1")).not.toThrow();
    expect(readStoredJson("ccb.x", { a: true }, isRecord)).toEqual({ a: true });
  });

  it("gives the fallback for damaged or unexpected JSON", () => {
    vi.stubGlobal("localStorage", fakeStorage({ good: '{"src":true}', bad: "{nope", wrong: "3" }));
    expect(readStoredJson("good", {}, isRecord)).toEqual({ src: true });
    expect(readStoredJson("bad", {}, isRecord)).toEqual({});
    expect(readStoredJson("wrong", {}, isRecord)).toEqual({});
    expect(readStoredJson("none", {}, isRecord)).toEqual({});
  });
});
