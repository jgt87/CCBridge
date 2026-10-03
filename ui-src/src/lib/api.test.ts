// Characterization tests for the API client: how events are cleaned and how server errors read.
// api.ts reads the session token from the page when it loads, so the page is stubbed first.
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { AgentEvent } from "./api";

type ApiModule = typeof import("./api");
let mod: ApiModule;

const reload = vi.fn();
const session = new Map<string, string>();

beforeAll(async () => {
  vi.stubGlobal("document", { querySelector: () => ({ content: "TOKEN" }) });
  vi.stubGlobal("location", { reload });
  vi.stubGlobal("sessionStorage", {
    getItem: (k: string) => session.get(k) ?? null,
    setItem: (k: string, v: string) => void session.set(k, v),
  });
  mod = await import("./api");
});

beforeEach(() => {
  reload.mockClear();
  session.clear();
});

const ev = (extra: Record<string, unknown>) => ({ seq: 1, type: "status", time: "12:00", ...extra }) as unknown as AgentEvent;

describe("normalizeEvent", () => {
  it("turns text fields into strings and leaves missing ones missing", () => {
    const e = mod.normalizeEvent(ev({ text: 5, output: { a: 1 }, error: null, id: "x" })) as unknown as Record<string, unknown>;
    expect(e.text).toBe("5");
    expect(e.output).toBe('{"a":1}');
    expect(e.error).toBeUndefined();
    expect(e.id).toBe("x");
    expect("summary" in e).toBe(false);
  });

  it("does not change the event it was given", () => {
    const raw = ev({ text: 5 });
    mod.normalizeEvent(raw);
    expect((raw as unknown as Record<string, unknown>).text).toBe(5);
  });

  it("cleans references: only objects, every field a string or null", () => {
    const e = mod.normalizeEvent(ev({ references: [{ title: 1, url: "u" }, null, "x"] }));
    expect(e.references).toEqual([{ title: "1", url: "u", kind: null }]);
    expect(mod.normalizeEvent(ev({ references: "nope" })).references).toEqual([]);
  });

  it("keeps item and file lists, and makes anything else an empty list", () => {
    const items = [{ text: "a", done: false }];
    expect(mod.normalizeEvent(ev({ items })).items).toBe(items);
    expect(mod.normalizeEvent(ev({ items: "x", files: 3 })).items).toEqual([]);
    expect(mod.normalizeEvent(ev({ files: 3 })).files).toEqual([]);
  });

  it("makes steps a list of non-empty strings; a single step is dropped", () => {
    expect(mod.normalizeEvent(ev({ steps: ["a", "", 2, null] })).steps).toEqual(["a", "2"]);
    expect(mod.normalizeEvent(ev({ steps: "one" })).steps).toEqual([]);
  });

  it("makes reasons a list of non-empty strings; a single reason becomes a list", () => {
    expect(mod.normalizeEvent(ev({ reasons: "one" })).reasons).toEqual(["one"]);
    expect(mod.normalizeEvent(ev({ reasons: ["a", "", 3] })).reasons).toEqual(["a", "3"]);
  });

  it("turns next into text", () => {
    expect(mod.normalizeEvent(ev({ next: 7 })).next).toBe("7");
    expect(mod.normalizeEvent(ev({ next: null })).next).toBeUndefined();
  });
});

describe("call (through api)", () => {
  const respond = (status: number, body: string) =>
    vi.stubGlobal("fetch", vi.fn(async () => new Response(body, { status, headers: { "Content-Type": "application/json" } })));

  it("sends the session token, and a JSON body only when there is one", async () => {
    respond(200, '{"files":[]}');
    await mod.api.files();
    let [, init] = (fetch as unknown as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(init.method).toBe("GET");
    expect(init.headers).toEqual({ "X-CCB-Token": "TOKEN" });
    expect(init.body).toBeUndefined();

    respond(200, '{"ok":true}');
    await mod.api.markHintShown("splitView");
    [, init] = (fetch as unknown as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(init.headers).toEqual({ "X-CCB-Token": "TOKEN", "Content-Type": "application/json" });
    expect(init.body).toBe('{"name":"splitView"}');
  });

  it("returns an empty object when the body is not JSON", async () => {
    respond(200, "not json");
    await expect(mod.api.markHintShown("x")).resolves.toEqual({});
  });

  it("reads the server's error, hint, error id and code", async () => {
    respond(500, '{"error":"Broke","hint":"Try again.","errId":"E-1","code":"X1"}');
    await expect(mod.api.markHintShown("x")).rejects.toThrow("Broke Try again. (error E-1, X1)");
    respond(400, '{"error":"Bad","errId":"E-2"}');
    await expect(mod.api.markHintShown("x")).rejects.toThrow(/^Bad \(error E-2\)$/);
    respond(502, "");
    await expect(mod.api.markHintShown("x")).rejects.toThrow(/^HTTP 502$/);
  });

  it("reloads once for a stale session token, not again within 10 seconds", async () => {
    respond(403, '{"error":"forbidden"}');
    await expect(mod.api.markHintShown("x")).rejects.toThrow("session expired; reload the page");
    expect(reload).toHaveBeenCalledTimes(1);
    await expect(mod.api.markHintShown("x")).rejects.toThrow("session expired; reload the page");
    expect(reload).toHaveBeenCalledTimes(1);
  });
});
