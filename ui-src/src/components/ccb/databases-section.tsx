import { useEffect, useState } from "react";
import type { DbConnection } from "@/lib/api";
import { cn } from "@/lib/utils";

const loadApi = () => import("@/lib/api").then((m) => m.api);
const buttonClass = "kit-btn kit-btn--ghost kit-btn--sm";
const inputClass = "kit-input h-8 min-h-8 w-full text-xs";

/**
 * Files > Project setup > Databases: SQL Server databases Copilot may query for this project, with
 * the person's Windows sign-in (never a password). Every query Copilot asks for waits for approval
 * and can only read (one SELECT, a read-only connection, everything rolled back).
 */
export function DatabasesSection({ projectPath }: { projectPath: string }) {
  const [items, setItems] = useState<DbConnection[]>([]);
  const [form, setForm] = useState({ name: "", server: "", database: "", trustCertificate: false });
  const [adding, setAdding] = useState(false);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    loadApi().then((api) => api.databases()).then(setItems, () => setItems([]));
  }, [projectPath]);
  const run = async (what: () => Promise<void>) => {
    setBusy(true);
    setNote("");
    try {
      await what();
    } catch (e) {
      setNote((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="space-y-1">
      <div className="text-muted-foreground">Databases (SQL Server, with your Windows sign-in: Copilot may query them, read-only, after you approve each query)</div>
      {items.map((d) => (
        <div className="flex items-center gap-2" key={d.name}>
          <span className="truncate" title={`${d.database} on ${d.server}`}>
            {d.name}: {d.database} on {d.server}
          </span>
          <button
            className={cn(buttonClass, "ml-auto shrink-0")}
            disabled={busy}
            onClick={() =>
              void run(async () => {
                const r = await (await loadApi()).dbOp({ op: "test", name: d.name });
                setNote(r.ok ? `${d.name}: connected.` : `${d.name}: ${r.error}`);
              })
            }
            type="button"
          >
            Test
          </button>
          <button className={cn(buttonClass, "shrink-0")} disabled={busy} onClick={() => void run(async () => setItems((await (await loadApi()).dbOp({ op: "remove", name: d.name })).items))} type="button">
            Remove
          </button>
        </div>
      ))}
      {adding ? (
        <div className="space-y-1">
          <input aria-label="Name for this database" className={inputClass} disabled={busy} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="Name (such as sales)" value={form.name} />
          <input aria-label="Server" className={inputClass} disabled={busy} onChange={(e) => setForm({ ...form, server: e.target.value })} placeholder="Server (such as SQL01 or SQL01\REPORTING)" value={form.server} />
          <input aria-label="Database" className={inputClass} disabled={busy} onChange={(e) => setForm({ ...form, database: e.target.value })} placeholder="Database name" value={form.database} />
          <label className="flex items-center gap-2 text-muted-foreground">
            <input checked={form.trustCertificate} className="kit-check" disabled={busy} onChange={(e) => setForm({ ...form, trustCertificate: e.target.checked })} type="checkbox" />
            Trust the certificate of the server (only when your IT department says so)
          </label>
          <div className="flex gap-1.5">
            <button
              className={cn(buttonClass, "bg-(--kit-surface-2)")}
              disabled={busy || !form.name.trim() || !form.server.trim() || !form.database.trim()}
              onClick={() =>
                void run(async () => {
                  setItems((await (await loadApi()).dbOp({ op: "add", ...form, name: form.name.trim() })).items);
                  setAdding(false);
                  setNote(`Added ${form.name.trim()}: use Test to check the connection.`);
                  setForm({ name: "", server: "", database: "", trustCertificate: false });
                })
              }
              type="button"
            >
              Add
            </button>
            <button className={buttonClass} disabled={busy} onClick={() => setAdding(false)} type="button">
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <button className={buttonClass} disabled={busy} onClick={() => setAdding(true)} type="button">
          Add a database
        </button>
      )}
      {note && <div className="text-muted-foreground">{note}</div>}
    </div>
  );
}
