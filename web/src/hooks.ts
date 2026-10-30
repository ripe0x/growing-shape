import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";
import { readGame, readOutcomes, readHistory } from "./chain";
import type { GameState, OutcomesResult, CycleEntry } from "./chain";
import { POLL_MS } from "./config";

// Poll a read function on an interval, exposing an imperative refresh for use
// right after a transaction. keepPrev avoids a flash of empty UI on re-fetch.
function usePolled<T>(fn: () => Promise<T>, deps: unknown[], enabled = true) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string>();
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    if (!enabled) return;
    try {
      const d = await fn();
      setData(d);
      setError(undefined);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to read chain.");
    } finally {
      setLoading(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  useEffect(() => {
    if (!enabled) {
      setData(null);
      setLoading(false);
      return;
    }
    let active = true;
    const run = () => {
      refresh().catch(() => {});
    };
    run();
    const t = setInterval(() => active && run(), POLL_MS);
    return () => {
      active = false;
      clearInterval(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [refresh, enabled]);

  return { data, error, loading, refresh };
}

export function useGame() {
  return usePolled<GameState>(() => readGame(), []);
}

export function useOutcomes(account?: Address) {
  return usePolled<OutcomesResult>(() => readOutcomes(account!), [account], !!account);
}

export function useHistory() {
  return usePolled<CycleEntry[]>(() => readHistory(), []);
}
