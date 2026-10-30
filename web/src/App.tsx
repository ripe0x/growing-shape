import { useEffect, useState } from "react";
import { useWallet } from "./wallet";
import { useGame, useOutcomes, useHistory } from "./hooks";
import { Featured } from "./components/Featured";
import { Prizes } from "./components/Prizes";
import { YourDraws } from "./components/YourDraws";
import { History } from "./components/History";
import { AccountButton, ConnectSheet } from "./components/Connect";
import { GAME_ADDRESS, CHAIN_ID, IS_LOCAL } from "./config";
import { shortAddr } from "./format";

function useTheme() {
  const [theme, setTheme] = useState<"light" | "dark" | null>(() => {
    try {
      return (localStorage.getItem("gs-theme") as "light" | "dark") || null;
    } catch {
      return null;
    }
  });
  useEffect(() => {
    const el = document.documentElement;
    if (theme) el.setAttribute("data-theme", theme);
    else el.removeAttribute("data-theme");
    try {
      if (theme) localStorage.setItem("gs-theme", theme);
      else localStorage.removeItem("gs-theme");
    } catch {
      /* private mode */
    }
  }, [theme]);
  const effective = theme ?? (window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  return { effective, toggle: () => setTheme(effective === "dark" ? "light" : "dark") };
}

export default function App() {
  const wallet = useWallet();
  const { effective, toggle } = useTheme();
  const [connectOpen, setConnectOpen] = useState(false);

  const game = useGame();
  const outcomes = useOutcomes(wallet.account);
  const history = useHistory();

  function onDrawn() {
    game.refresh();
    outcomes.refresh();
    history.refresh();
  }

  return (
    <div className="app">
      <header className="header">
        <div className="brand">
          <h1>Growing Shape</h1>
          <small>An onchain drawing game</small>
        </div>
        <div className="header-actions">
          <button className="icon-btn" aria-label="Toggle theme" title="Toggle light / dark" onClick={toggle}>
            {effective === "dark" ? (
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" /></svg>
            ) : (
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></svg>
            )}
          </button>
          <AccountButton wallet={wallet} onOpen={() => setConnectOpen(true)} />
        </div>
      </header>

      <main>
        {!GAME_ADDRESS ? (
          <div className="card" style={{ marginTop: 28 }}><div className="center-muted">Not configured. Copy <code>web/.env.example</code> to <code>web/.env</code> and set <code>VITE_GAME_ADDRESS</code>.</div></div>
        ) : game.error && !game.data ? (
          <div className="card" style={{ marginTop: 28 }}><div className="center-muted">Could not reach the game at {shortAddr(GAME_ADDRESS)} on chain {CHAIN_ID}.<br />{game.error}</div></div>
        ) : !game.data ? (
          <div className="card" style={{ marginTop: 28 }}><div className="center-muted"><span className="spin" /> Loading…</div></div>
        ) : (
          <>
            <Featured
              game={game.data}
              account={wallet.account}
              walletClient={wallet.walletClient}
              wrongChain={wallet.wrongChain}
              onConnect={() => setConnectOpen(true)}
              onDrawn={onDrawn}
            />
            <Prizes game={game.data} />
            {wallet.account && (
              <YourDraws
                pool={game.data.pool}
                account={wallet.account}
                walletClient={wallet.walletClient}
                data={outcomes.data}
                onChanged={onDrawn}
              />
            )}
            <History shapes={game.data.shapes} entries={history.data} loading={history.loading} />
          </>
        )}
      </main>

      <footer className="footer">
        <span>{IS_LOCAL ? "Local anvil fork" : CHAIN_ID === 1 ? "Ethereum mainnet" : `Chain ${CHAIN_ID}`}</span>
        <code>{GAME_ADDRESS}</code>
        <span>Verified from chain. Not financial advice.</span>
      </footer>

      <ConnectSheet wallet={wallet} open={connectOpen} onClose={() => setConnectOpen(false)} />
    </div>
  );
}
