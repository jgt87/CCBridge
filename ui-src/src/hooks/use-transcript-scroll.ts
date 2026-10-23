import { type RefObject, useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { followBottom } from "@/lib/stick-to-bottom";

/** The element that scrolls the chat (the nearest parent with its own scrollbar). */
function scrollParent(el: HTMLElement): HTMLElement | null {
  for (let p = el.parentElement; p; p = p.parentElement) {
    const y = getComputedStyle(p).overflowY;
    if (y === "auto" || y === "scroll") return p;
  }
  return null;
}
const scrollParentOf = (el: HTMLElement | null) => (el ? scrollParent(el) : null);

/** Stay at the newest line while anything grows (a reply streaming in, a card getting its output,
 *  code and images laying out), unless the reader scrolled up to read. Sending a message (`lastIsUser`),
 *  or a step that waits for approval, brings the view back to the bottom. */
export function useFollowBottom(contentRef: RefObject<HTMLDivElement | null>, showEmpty: boolean, count: number, lastIsUser: boolean, awaiting: boolean) {
  const follower = useRef<ReturnType<typeof followBottom> | null>(null);
  useEffect(() => {
    const content = contentRef.current;
    const scroller = content ? scrollParent(content) : null;
    if (!content || !scroller) return;
    const f = followBottom(scroller, content);
    follower.current = f;
    return () => {
      f.stop();
      follower.current = null;
    };
  }, [contentRef, showEmpty]);
  useEffect(() => {
    if (lastIsUser || awaiting) follower.current?.stick();
  }, [count, lastIsUser, awaiting]);
}

/** The newest `page` items; scrolling up to the oldest one shown loads `page` more, keeping the place.
 *  A new `firstKey` (a new chat, project or cleared history) starts over. */
export function usePagedItems<T>(items: T[], firstKey: string | number, page: number, endRef: RefObject<HTMLDivElement | null>) {
  const [shown, setShown] = useState(page);
  useEffect(() => setShown(page), [firstKey, page]);
  const hidden = Math.max(0, items.length - shown);
  const visible = hidden ? items.slice(hidden) : items;
  const topRef = useRef<HTMLDivElement>(null);
  const keepFromBottom = useRef<number | null>(null);
  const loadEarlier = useCallback(() => {
    const scroller = scrollParentOf(topRef.current);
    if (scroller) keepFromBottom.current = scroller.scrollHeight - scroller.scrollTop;
    setShown((n) => n + page);
  }, [page]);
  useEffect(() => {
    const el = topRef.current;
    if (!hidden || !el) return;
    const io = new IntersectionObserver(([e]) => e.isIntersecting && loadEarlier(), { root: scrollParent(el), rootMargin: "120px 0px 0px 0px" });
    io.observe(el);
    return () => io.disconnect();
  }, [hidden, shown, loadEarlier]);
  useLayoutEffect(() => {
    const scroller = scrollParentOf(topRef.current ?? endRef.current);
    if (scroller && keepFromBottom.current !== null) scroller.scrollTop = scroller.scrollHeight - keepFromBottom.current;
    keepFromBottom.current = null;
  }, [endRef, shown]);
  return { hidden, visible, topRef, loadEarlier };
}
