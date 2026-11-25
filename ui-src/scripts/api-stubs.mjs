// The app's data in every browser check, answered the same way: a request whose path is a key of the
// config's "api" gets that value as JSON; a write (POST, PUT, PATCH, DELETE) to any other path is
// blocked with a 405 and reported, so a check that clicks "Create" or "Run" never reaches a server
// that could store it. Other reads go through, as the page asked.
// "api" keys are any path: "/api/status", "/data/demo/atlas.json". Invented data only.
//
// Used by check-design-rules.mjs (and through its withBrowser by check-a11y, check-elements and
// check-interaction), by check-control-rows.mjs (--config), and by design-checks.mjs's test server.
// Before, only the shared browser layer answered "api" and nothing stopped a write: the row check
// opened the app unstubbed, and a dialog's submit could POST a job to the app's own server (a test
// audit, 24 Nov 2026).

export const WRITES = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);
export const BLOCKED_BODY = { error: 'blocked by the check: a write to a path not listed in design-check.json "api"' };

/** What a request gets: { status, body } to answer it here (with `blocked` set for a refused
 *  write), or null to let it through. A read under a listed path that is not itself listed is a
 *  404, as the browser layer always answered it. */
export function answer(api, method, url) {
  let path;
  try { path = decodeURIComponent(new URL(url, 'http://x').pathname); } catch { return null; }
  if (api && Object.hasOwn(api, path)) return { status: 200, body: api[path] };
  if (WRITES.has(String(method).toUpperCase())) return { status: 405, body: BLOCKED_BODY, blocked: `${String(method).toUpperCase()} ${path}` };
  if (api && Object.keys(api).some((k) => url.includes(k))) return { status: 404, body: { error: 'not in design-check.json "api"' } };
  return null;
}

/** A DevTools stub for one browser: enable(S) in each tab, paused(send, m) on Fetch.requestPaused;
 *  `blocked` lists each refused write once. */
export function stubs(api) {
  const blocked = [];
  return {
    blocked,
    enable: (S) => S('Fetch.enable', { patterns: [{ urlPattern: '*', requestStage: 'Request' }] }),
    paused(send, m) {
      const { requestId, request } = m.params;
      const a = answer(api, request.method, request.url);
      if (!a) return send('Fetch.continueRequest', { requestId }, m.sessionId).catch(() => {});
      if (a.blocked && !blocked.includes(a.blocked)) blocked.push(a.blocked);
      return send('Fetch.fulfillRequest', { requestId, responseCode: a.status, responseHeaders: [{ name: 'Content-Type', value: 'application/json' }],
        body: Buffer.from(JSON.stringify(a.body)).toString('base64') }, m.sessionId).catch(() => {});
    },
  };
}

/** The report of refused writes, or '' when there were none. Printed before the check's own
 *  results; its lines carry no [tag], so no finding parser reads them as a rule. */
export function blockedReport(blocked) {
  if (!blocked.length) return '';
  return `Blocked requests (${blocked.length}; writes to paths not listed in design-check.json "api", answered 405 so nothing reached a server):\n${blocked.map((b) => `  ${b}`).join('\n')}`;
}
