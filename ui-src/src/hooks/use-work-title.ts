import { useEffect, useRef } from "react";
import type { WorkStatus } from "@/lib/api";
import { notify } from "@/lib/notify";
import { isNewQuietSpell, tabTitle } from "@/lib/work-status";

/** The browser tab's title says what StreamHub is doing and for how long (seen from another tab),
 *  and a long silence gets one desktop notification per quiet spell (only while the tab is hidden). */
export function useWorkTitle(busy: boolean, work: WorkStatus | null | undefined) {
  const workRef = useRef({ busy: false, work: null as WorkStatus | null | undefined });
  workRef.current = { busy, work };
  const quietNoticed = useRef("");
  useEffect(() => {
    const update = () => {
      const { busy, work } = workRef.current;
      document.title = tabTitle(busy, work);
      if (isNewQuietSpell(busy, work, quietNoticed.current)) {
        quietNoticed.current = work.lastSignAt;
        notify("StreamHub: nothing new for a while", `${work.phase}. Open StreamHub to see Copilot or stop the task.`);
      }
    };
    update();
    const t = window.setInterval(update, 15000);
    return () => window.clearInterval(t);
  }, []);
  useEffect(() => {
    document.title = tabTitle(busy, work);
  }, [busy, work]);
}
