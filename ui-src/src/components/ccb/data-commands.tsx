import { BookmarkPlus, FileSpreadsheet } from "lucide-react";
import type { Action } from "@/components/kokonutui/action-search-bar";
import type { CommandContext } from "@/components/ccb/command-palette";
import type { DataProfileSource } from "@/lib/api";

export type { DataProfileSource };

/** The server calls these commands use (the matching methods of `api`). */
export interface DataCommandApi {
  dataProfileSources: () => Promise<{ items: DataProfileSource[] }>;
  dataProfile: (source: string) => Promise<{ ok: boolean; queued: string }>;
  runbookFromChat: () => Promise<{ ok: boolean; queued?: string; name?: string; error?: string }>;
}

const icon = (Icon: typeof FileSpreadsheet) => <Icon className="h-4 w-4 text-muted-foreground" />;

/** One line about a data file: how much it holds as last converted. */
export function sourceDescription(s: DataProfileSource): string {
  if (!s.rows && !s.columns) return `${s.source}: a report of its rows, columns, empty cells, outliers and duplicates`;
  const sheets = s.sheets > 1 ? `, ${s.sheets} sheets` : "";
  return `${s.source}: ${s.rows.toLocaleString()} row(s), ${s.columns} column(s)${sheets}`;
}

/** The data files to profile (the second list, after "Data profile report"). */
export function dataProfileActions(ctx: CommandContext, items: DataProfileSource[], api: DataCommandApi): Action[] {
  return items.map((s) => ({
    id: `profile:${s.source}`,
    label: s.source.split("/").pop() ?? s.source,
    description: sourceDescription(s),
    icon: icon(FileSpreadsheet),
    end: "Profile",
    onSelect: () =>
      api.dataProfile(s.source).then(
        () => ctx.notice({ text: `Making the data profile of ${s.source}. It is saved in Runbooks/Exports as a page and an Excel workbook.` }),
        (e) => ctx.fail((e as Error).message)
      ),
  }));
}

/** The command menu entries: the data profile (opens the list of data files) and saving the last request as a runbook. */
export function dataCommands<K extends string>(ctx: CommandContext, show: (p: K) => void, list: K, setSources: (items: DataProfileSource[]) => void, api: DataCommandApi): Action[] {
  return [
    {
      id: "data-profile",
      label: "Data profile report",
      description: "Pick a data file: its rows, columns, empty cells, outliers, mixed values and duplicates, as a page and an Excel workbook",
      icon: icon(FileSpreadsheet),
      end: "Data",
      onSelect: () =>
        api.dataProfileSources().then(
          (r) => {
            if (!r.items.length) { ctx.notice({ text: "This project has no converted data files yet. Put a CSV, TSV or Excel file in the project (JSON in Source/), and StreamHub converts it with the next request." }); return; }
            setSources(r.items);
            setTimeout(() => show(list), 0);
          },
          (e) => ctx.fail((e as Error).message)
        ),
    },
    {
      id: "runbook-from-chat",
      label: "Save the last request as a runbook",
      description: "Copilot writes a runbook that does your last request in this chat again, to run later or on a schedule",
      icon: icon(BookmarkPlus),
      end: "Runbooks",
      onSelect: () =>
        api.runbookFromChat().then(
          (r) => (r.ok ? ctx.notice({ text: `Asked Copilot to write Runbooks/${r.name}.runbook.md from your last request.` }) : ctx.fail(r.error || "The last request cannot be saved as a runbook.")),
          (e) => ctx.fail((e as Error).message)
        ),
    },
  ];
}
