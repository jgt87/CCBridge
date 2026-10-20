import { api } from "@/lib/api";

/** The side panel's server calls: a failure goes to the error bar; those that write files refresh the tree. */
export function useSidePanelActions(fail: (e: unknown) => void, refreshFiles: () => void) {
  const orFail = <A extends unknown[]>(f: (...a: A) => Promise<unknown>) => (...a: A) => f(...a).catch(fail);
  const thenRefresh = <A extends unknown[]>(f: (...a: A) => Promise<unknown>) => async (...a: A) => {
    await f(...a);
    refreshFiles();
  };
  return {
    onRunFetch: orFail(api.runFetch),
    onSaveFetch: thenRefresh(api.saveFetch),
    onUndo: () => api.undo(),
    onUndoTo: orFail(api.undo),
    onUploaded: refreshFiles,
    onCreateRunbook: thenRefresh(api.createRunbook),
    onRunRunbook: orFail(api.runRunbook),
    onCreateChain: thenRefresh(api.createChain),
    onRunChain: orFail(api.runChain),
    onRunScript: orFail(api.runScript),
    onChainSteps: thenRefresh(api.chainSteps),
  };
}
