import { api, type EdgeCacheInfo, type Setting, type SsoStatus, type ToolItem } from "@/lib/api";

/**
 * What Settings shows, loaded once in the background after the app starts, so the panel opens
 * complete instead of filling in piece by piece. The panel refreshes these quietly while open.
 */
let settings: Setting[] | null = null;
let sso: SsoStatus | null = null;
let edge: EdgeCacheInfo | null = null;
let tools: ToolItem[] | null = null;

export const cachedSettings = () => settings;
export const cachedSso = () => sso;
export const cachedEdgeCache = () => edge;
export const cachedTools = () => tools;

export function rememberSettings(list: Setting[]) {
  settings = list;
}
export function rememberSso(status: SsoStatus | null) {
  sso = status;
}
export function rememberEdgeCache(info: EdgeCacheInfo | null) {
  edge = info;
}

export const loadSettings = () => api.settings().then((s) => (rememberSettings(s), s));
export const loadSso = () => api.ssoStatus().then((s) => (rememberSso(s), s));
export const loadEdgeCache = () => api.edgeCache().then((i) => (rememberEdgeCache(i), i));
export const loadTools = () => api.tools().then((t) => ((tools = t), t));

/** All of them, failures ignored (the panel loads them again when it opens). */
export function prefetchSettings() {
  return Promise.allSettled([loadSettings(), loadEdgeCache(), loadSso(), loadTools()]);
}
