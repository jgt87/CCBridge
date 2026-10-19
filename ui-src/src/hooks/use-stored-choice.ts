import { useCallback, useState } from "react";

/** A choice remembered in this browser (localStorage). Storage can be blocked (a private window,
 *  site data off): then the choice starts from `parse(null)` and holds for this session only. */
export function useStoredChoice<T>(key: string, parse: (raw: string | null) => T, show: (value: T) => string) {
  const [value, setValue] = useState<T>(() => {
    try {
      return parse(localStorage.getItem(key));
    } catch {
      return parse(null);
    }
  });
  const set = useCallback(
    (v: T) => {
      setValue(v);
      try {
        localStorage.setItem(key, show(v));
      } catch {
        /* storage blocked: only this session */
      }
    },
    [key, show]
  );
  return [value, set] as const;
}
