import type React from "react";

// External links (the changelog, cited sources, links in replies). In Edge's Split screen a link
// clicked in one pane opens in the other pane, replacing Copilot, even with target="_blank". When
// the app is a tab in StreamHub's Edge, the click goes to the server instead, which opens a real
// new tab there; everywhere else the browser opens the link as usual.

let throughEdge = false;

/** Set from the app state (appInEdge). */
export function setLinksThroughEdge(on: boolean) {
  throughEdge = on;
}

/** onClick for an external <a target="_blank">: opens it as a new tab when the app is in Edge. */
export function openExternal(e: React.MouseEvent<HTMLAnchorElement>) {
  const href = e.currentTarget.href;
  if (!throughEdge || !/^https?:\/\//i.test(href) || e.ctrlKey || e.metaKey || e.shiftKey) return;
  e.preventDefault();
  // The API client is loaded on the first click: it reads the page's session token when loaded.
  import("./api")
    .then(({ api }) => api.openLink(href))
    .then(
      (r) => {
        if (!r.opened) window.open(href, "_blank", "noopener,noreferrer");
      },
      () => window.open(href, "_blank", "noopener,noreferrer"),
    );
}
