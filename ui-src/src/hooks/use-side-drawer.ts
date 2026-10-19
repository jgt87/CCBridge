import { useEffect, useState } from "react";

const WIDE = "(min-width: 1024px)";

/** Side panel: always beside the chat when the window is wide enough. On a narrow window it is hidden
 *  and a button (shown only then) opens it over the chat; a click beside it or Esc closes it. */
export function useSideDrawer() {
  const [wide, setWide] = useState(() => window.matchMedia(WIDE).matches);
  const [drawerOpen, setDrawerOpen] = useState(false);
  useEffect(() => {
    if (!drawerOpen) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setDrawerOpen(false);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [drawerOpen]);
  useEffect(() => {
    const mq = window.matchMedia(WIDE);
    const onChange = () => {
      setWide(mq.matches);
      setDrawerOpen(false);
    };
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);
  return { wide, drawerOpen, setDrawerOpen, sideVisible: wide || drawerOpen };
}
