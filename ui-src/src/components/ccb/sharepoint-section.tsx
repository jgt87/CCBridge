import { useEffect, useState } from "react";
import HoldButton from "@/components/kokonutui/hold-button";
import type { SharePointSource } from "@/lib/api";
import { cn } from "@/lib/utils";

const loadApi = () => import("@/lib/api").then((m) => m.api);
const buttonClass = "kit-btn kit-btn--ghost kit-btn--sm";
const inputClass = "kit-input h-8 min-h-8 w-full text-xs";

/**
 * Files > Project setup, for a project whose pages are SharePoint HTML pages: the SharePoint files
 * and lists linked for the page's LiveData (resolved with the person's own sign-in in StreamHub's
 * Edge; Copilot gets the exact manifest entries), and publishing a page to a site's Site Pages
 * library: first a look (where it goes, whether a page of that name is there, what the checks still
 * find), then the upload with a hold-to-confirm button, replacing only when that is confirmed too.
 */
export function SharePointSection({ projectPath }: { projectPath: string }) {
  const [sources, setSources] = useState<SharePointSource[]>([]);
  const [pages, setPages] = useState<string[]>([]);
  const [link, setLink] = useState("");
  const [site, setSite] = useState("");
  const [page, setPage] = useState("");
  const [look, setLook] = useState<{ target: string; exists: boolean; findings: string[] } | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    loadApi().then((api) => api.sharePoint()).then(
      (r) => {
        setSources(r.sources);
        setPages(r.pages);
        setSite(r.site);
        setPage(r.page || r.pages.find((p) => /^index\.html?$/i.test(p)) || r.pages[0] || "");
      },
      () => setSources([]),
    );
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
    <div className="space-y-2">
      <div className="space-y-1">
        <div className="text-muted-foreground">SharePoint data for the page (LiveData: read with the access of each viewer)</div>
        <input aria-label="Link to a SharePoint file or list" className={inputClass} disabled={busy} onChange={(e) => setLink(e.target.value)} placeholder="https://...sharepoint.com/... (a file or a list)" value={link} />
        <button
          className={cn(buttonClass, "bg-(--kit-surface-2)")}
          disabled={busy || !link.trim()}
          onClick={() =>
            void run(async () => {
              const r = await (await loadApi()).linkSharePoint(link.trim());
              setSources(r.sources);
              setLink("");
              setNote(`Linked: ${r.source.label || r.source.fileName}. Copilot gets its LiveData entry with every task.`);
            })
          }
          title="Looks the file or list up in SharePoint with your sign-in in StreamHub's Edge"
          type="button"
        >
          Link
        </button>
        {sources.map((s) => (
          <div className="flex items-center gap-2" key={s.spItemUrl}>
            <span className="truncate" title={s.spItemUrl}>
              {s.kind === "list" ? `List: ${s.label}` : s.fileName}
            </span>
            <button
              className={cn(buttonClass, "ml-auto shrink-0")}
              disabled={busy}
              onClick={() => void run(async () => setSources((await (await loadApi()).unlinkSharePoint(s.spItemUrl)).sources))}
              type="button"
            >
              Remove
            </button>
          </div>
        ))}
      </div>
      <div className="space-y-1">
        <div className="text-muted-foreground">Publish a page to the Site Pages of a site</div>
        <input aria-label="SharePoint site address" className={inputClass} disabled={busy} onChange={(e) => { setSite(e.target.value); setLook(null); }} placeholder="https://...sharepoint.com/sites/NAME" value={site} />
        <select aria-label="Page to publish" className="kit-select h-8 min-h-8 w-full text-xs" disabled={busy || !pages.length} onChange={(e) => { setPage(e.target.value); setLook(null); }} value={page}>
          {pages.map((p) => (
            <option key={p} value={p}>
              {p}
            </option>
          ))}
        </select>
        {!look ? (
          <button
            className={cn(buttonClass, "bg-(--kit-surface-2)")}
            disabled={busy || !site.trim() || !page}
            onClick={() => void run(async () => setLook(await (await loadApi()).publishSharePoint({ site: site.trim(), file: page })))}
            type="button"
          >
            Check before publishing
          </button>
        ) : (
          <div className="space-y-1">
            <div className="text-muted-foreground">
              {look.exists ? "A page of this name is already there and would be replaced: " : "It goes to "}
              {look.target}
            </div>
            {look.findings.length > 0 && (
              <div className="kit-notice kit-notice--warn text-xs">
                The checks still find {look.findings.length} thing(s) SharePoint blocks or loses, such as: {look.findings[0]}
              </div>
            )}
            <div className="flex items-center gap-1.5">
              <HoldButton
                className="h-10 min-w-44"
                disabled={busy}
                holdDuration={1200}
                holdingLabel="Keep holding..."
                label={look.exists ? "Hold to replace" : "Hold to publish"}
                variant="grey"
                onHoldComplete={() =>
                  void run(async () => {
                    const r = await (await loadApi()).publishSharePoint({ site: site.trim(), file: page, confirm: true, replace: look.exists });
                    setLook(null);
                    setNote(`Published${r.replaced ? " (replaced)" : ""}: ${r.target}`);
                  })
                }
              />
              <button className={buttonClass} disabled={busy} onClick={() => setLook(null)} type="button">
                Cancel
              </button>
            </div>
          </div>
        )}
      </div>
      {note && <div className="text-muted-foreground">{note}</div>}
    </div>
  );
}
