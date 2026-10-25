import { CloudDownload, Info } from "lucide-react";
import { useState } from "react";
import { linkLabel, type SandboxFetchItem } from "./pptx-outline-view";

const loadApi = () => import("@/lib/api").then((m) => m.api);

/**
 * Under a reply that names a file in Copilot's own workspace (sandbox:/mnt/data/NAME), which never
 * reaches the project: a button per file that asks Copilot, in the same chat, to save it to your
 * OneDrive and give the link. Only when pressed; StreamHub never confirms anything Copilot asks.
 */
export function SandboxButtons({ files }: { files: string[] }) {
  const [said, setSaid] = useState<Record<string, string>>({});
  if (!files.length) return null;
  const ask = async (name: string) => {
    setSaid((s) => ({ ...s, [name]: "Asking Copilot..." }));
    try {
      await (await loadApi()).sandboxSave(name);
      setSaid((s) => ({ ...s, [name]: "Asked. When Copilot answers with a OneDrive link, a card offers to fetch the file." }));
    } catch (e) {
      setSaid((s) => ({ ...s, [name]: (e as Error).message }));
    }
  };
  return (
    <div className="mt-2 space-y-1">
      {files.map((f) => (
        <div className="flex flex-wrap items-center gap-2 text-xs" key={f}>
          <span className="text-muted-foreground">{`${f} is in Copilot's own workspace, not in the project.`}</span>
          {said[f] ? (
            <span className="text-muted-foreground">{said[f]}</span>
          ) : (
            <button className="kit-btn kit-btn--sm" onClick={() => void ask(f)} type="button">
              <CloudDownload className="h-3.5 w-3.5" />
              Ask Copilot to save it to OneDrive and fetch it
            </button>
          )}
        </div>
      ))}
    </div>
  );
}

/**
 * Copilot's answer about saving the file: a Fetch button per OneDrive or SharePoint link (StreamHub's
 * Edge downloads it into Downloads/ after you approve it); without a link, how to make a deck instead.
 */
export function SandboxFetchCard({ item }: { item: SandboxFetchItem }) {
  const [done, setDone] = useState("");
  if (item.restored) return null;
  const fetchIt = async (url: string) => {
    try {
      await (await loadApi()).sandboxFetch(url, item.file);
      setDone("Fetching: approve the download on the card that follows. A deck then gets the template card with it.");
    } catch (e) {
      setDone((e as Error).message);
    }
  };
  const outline = async () => {
    try {
      await (await loadApi()).pptxOutline();
      setDone("The outline card is in the chat.");
    } catch (e) {
      setDone((e as Error).message);
    }
  };
  return (
    <div className="kit-panel space-y-2 text-sm">
      <div className="flex items-center gap-2 font-medium">
        <CloudDownload className="h-4 w-4 text-muted-foreground" />
        {item.file ? `${item.file} from Copilot's workspace` : "A file from Copilot's workspace"}
      </div>
      {item.human && (
        <div className="kit-notice flex items-start gap-2 text-xs">
          <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" />
          Copilot asked for a confirmation. StreamHub never confirms it: do that yourself in the Copilot window if you want the file saved, then ask again.
        </div>
      )}
      {item.links.length ? (
        <div className="space-y-1">
          {item.links.map((l) => (
            <div className="flex flex-wrap items-center gap-2 text-xs" key={l}>
              <span className="min-w-0 flex-1 truncate" title={l}>
                {linkLabel(l)}
              </span>
              <button className="kit-btn kit-btn--sm" disabled={Boolean(done)} onClick={() => void fetchIt(l)} type="button">
                Fetch into Downloads/
              </button>
            </div>
          ))}
        </div>
      ) : (
        <div className="space-y-2 text-xs">
          <div className="text-muted-foreground">{"Copilot's answer has no OneDrive or SharePoint link to fetch. For a deck, ask Copilot for a deck outline instead (Work/NAME.deck.json): StreamHub builds it on your template."}</div>
          <button className="kit-btn kit-btn--sm" disabled={Boolean(done)} onClick={() => void outline()} type="button">
            Build a deck from an outline
          </button>
        </div>
      )}
      {done && <div className="text-muted-foreground text-xs">{done}</div>}
    </div>
  );
}
