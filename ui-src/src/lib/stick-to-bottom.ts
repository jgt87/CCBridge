/**
 * Keeping a chat view at its newest line while things arrive: the view follows the bottom while
 * the reader is there (within a small margin), and stops following once they scroll up to read.
 */

/** How close to the bottom still counts as "at the bottom" (px). */
export const STICK_MARGIN = 80;

/** Whether a scroll position is at the bottom, give or take the margin. */
export function isNearBottom(scrollHeight: number, scrollTop: number, clientHeight: number, margin = STICK_MARGIN): boolean {
  return scrollHeight - scrollTop - clientHeight <= margin;
}

/**
 * Follows the bottom of `scroller` while `content` grows (a reply streaming in, a card getting its
 * output, images and code laying out), as long as the reader was at the bottom. Returns a function
 * that stops it, and `stick()` to follow again (after the reader sends a message).
 */
export function followBottom(scroller: HTMLElement, content: HTMLElement): { stop: () => void; stick: () => void } {
  let follow = isNearBottom(scroller.scrollHeight, scroller.scrollTop, scroller.clientHeight);
  let lastTop = scroller.scrollTop;
  const toBottom = () => {
    scroller.scrollTop = scroller.scrollHeight;
    lastTop = scroller.scrollTop;
  };
  const onScroll = () => {
    const near = isNearBottom(scroller.scrollHeight, scroller.scrollTop, scroller.clientHeight);
    // Moving up away from the bottom is the reader; growth below them never moves scrollTop up.
    if (scroller.scrollTop < lastTop && !near) follow = false;
    else if (near) follow = true;
    lastTop = scroller.scrollTop;
  };
  const grew = () => {
    if (follow) toBottom();
  };
  scroller.addEventListener("scroll", onScroll, { passive: true });
  const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(grew) : null;
  ro?.observe(content);
  if (follow) toBottom();
  return {
    stop: () => {
      scroller.removeEventListener("scroll", onScroll);
      ro?.disconnect();
    },
    stick: () => {
      follow = true;
      toBottom();
    },
  };
}
