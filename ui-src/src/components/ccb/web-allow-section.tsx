import { useEffect, useState } from "react";
import { cn } from "@/lib/utils";

const loadApi = () => import("@/lib/api").then((m) => m.api);
const buttonClass = "kit-btn kit-btn--ghost kit-btn--sm";

/**
 * Files > Project setup: the web sites (or parts of one) the person allowed when approving a read
 * ("everything under ..., from now on"). Copilot reads pages under them without asking; Remove asks again.
 */
export function WebAllowSection({ projectPath }: { projectPath: string }) {
  const [items, setItems] = useState<string[]>([]);
  useEffect(() => {
    loadApi().then((api) => api.webAllow()).then(setItems, () => setItems([]));
  }, [projectPath]);
  if (!items.length) return null;
  return (
    <div className="space-y-1">
      <div className="text-muted-foreground">Web sites Copilot reads without asking (allowed when you approved a read)</div>
      {items.map((s) => (
        <div className="flex items-center gap-2" key={s}>
          <span className="truncate font-mono" title={s}>
            {s}
          </span>
          <button className={cn(buttonClass, "ml-auto shrink-0")} onClick={() => void loadApi().then((api) => api.removeWebAllow(s)).then(setItems)} type="button">
            Remove
          </button>
        </div>
      ))}
    </div>
  );
}
