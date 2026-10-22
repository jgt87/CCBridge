import { useEffect } from "react";
import { setLinksThroughEdge } from "@/lib/links";
import { prefetchSettings } from "@/lib/settings-cache";

/** Set up once the app runs: links and the Settings prefetch. */
export function useAppSetup(appInEdge: boolean | undefined) {
  // External links open through StreamHub's Edge when the app is a tab there (lib/links.ts).
  useEffect(() => setLinksThroughEdge(Boolean(appInEdge)), [appInEdge]);

  // Settings opens complete: what it shows is loaded once in the background, a little after start.
  useEffect(() => {
    const t = window.setTimeout(() => void prefetchSettings(), 4000);
    return () => window.clearTimeout(t);
  }, []);
}
