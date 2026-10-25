import { describe, expect, it, vi } from "vitest";
import type { CommandContext } from "./command-palette";
import { dataCommands, dataProfileActions, type DataCommandApi, type DataProfileSource, sourceDescription } from "./data-commands";

const csv: DataProfileSource = { source: "Source/sales.csv", output: "data/sales.json", rows: 1250, columns: 6, sheets: 1, size: 4000 };
const book: DataProfileSource = { source: "Source/book.xlsx", output: "data/book.json", rows: 5, columns: 3, sheets: 2, size: 9000 };

function setup(over: Partial<DataCommandApi> = {}) {
  const notice = vi.fn();
  const fail = vi.fn();
  const ctx = { notice, fail } as unknown as CommandContext;
  const api: DataCommandApi = {
    dataProfileSources: vi.fn(() => Promise.resolve({ items: [csv, book] })),
    dataProfile: vi.fn(() => Promise.resolve({ ok: true, queued: "q1" })),
    runbookFromChat: vi.fn(() => Promise.resolve({ ok: true, queued: "q2", name: "list-my-meetings" })),
    ...over,
  };
  return { ctx, api, notice, fail };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("sourceDescription", () => {
  it("says how much a data file holds", () => {
    expect(sourceDescription(csv)).toBe(`Source/sales.csv: ${(1250).toLocaleString()} row(s), 6 column(s)`);
    expect(sourceDescription(book)).toBe("Source/book.xlsx: 5 row(s), 3 column(s), 2 sheets");
    expect(sourceDescription({ ...csv, rows: 0, columns: 0 })).toMatch(/a report of its rows/);
  });
});

describe("data commands", () => {
  it("opens the list of data files, or says there are none", async () => {
    const { ctx, api, notice } = setup();
    const show = vi.fn();
    const setSources = vi.fn();
    const [profile] = dataCommands(ctx, show, "dataprofile", setSources, api);
    profile.onSelect?.();
    await flush();
    await flush();
    expect(setSources).toHaveBeenCalledWith([csv, book]);
    expect(show).toHaveBeenCalledWith("dataprofile");

    const empty = setup({ dataProfileSources: () => Promise.resolve({ items: [] }) });
    const show2 = vi.fn();
    dataCommands(empty.ctx, show2, "dataprofile", vi.fn(), empty.api)[0].onSelect?.();
    await flush();
    expect(show2).not.toHaveBeenCalled();
    expect(empty.notice.mock.calls[0][0].text).toMatch(/no converted data files/);
    expect(notice).not.toHaveBeenCalled();
  });

  it("queues the profile of the picked file", async () => {
    const { ctx, api, notice } = setup();
    const actions = dataProfileActions(ctx, [csv, book], api);
    expect(actions.map((a) => a.label)).toEqual(["sales.csv", "book.xlsx"]);
    actions[1].onSelect?.();
    await flush();
    expect(api.dataProfile).toHaveBeenCalledWith("Source/book.xlsx");
    expect(notice.mock.calls[0][0].text).toMatch(/Runbooks\/Exports/);
  });

  it("asks Copilot for the runbook, or shows why the last request cannot become one", async () => {
    const { ctx, api, notice } = setup();
    dataCommands(ctx, vi.fn(), "dataprofile", vi.fn(), api)[1].onSelect?.();
    await flush();
    expect(notice.mock.calls[0][0].text).toBe("Asked Copilot to write Runbooks/list-my-meetings.runbook.md from your last request.");

    const refused = setup({ runbookFromChat: () => Promise.resolve({ ok: false, error: "The last request was plain chat." }) });
    dataCommands(refused.ctx, vi.fn(), "dataprofile", vi.fn(), refused.api)[1].onSelect?.();
    await flush();
    expect(refused.fail).toHaveBeenCalledWith("The last request was plain chat.");
  });
});
