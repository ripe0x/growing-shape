import type { Wallet } from "../wallet";
import { shortAddr } from "../format";
import { IS_LOCAL, LOCAL_ACCOUNTS, WALLETCONNECT_PROJECT_ID } from "../config";

export function AccountButton({ wallet, onOpen }: { wallet: Wallet; onOpen: () => void }) {
  return (
    <button className="btn" onClick={onOpen}>
      {wallet.account ? shortAddr(wallet.account) : "Connect"}
    </button>
  );
}

export function ConnectSheet({ wallet, open, onClose }: { wallet: Wallet; open: boolean; onClose: () => void }) {
  if (!open) return null;
  const { account, connectors, connectInjected, connectLocal, disconnect, wrongChain, error } = wallet;

  return (
    <div className="sheet-backdrop" onClick={onClose}>
      <div className="sheet" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Connect wallet">
        {account ? (
          <>
            <h3>Connected</h3>
            <div className="bar"><span className="mono">{shortAddr(account)}</span>
              <button className="btn btn-ghost" onClick={() => { disconnect(); onClose(); }}>Disconnect</button>
            </div>
            {wrongChain && <div className="warn-banner">Your wallet is on the wrong network. Switch it to continue.</div>}
          </>
        ) : (
          <>
            <h3>Connect a wallet</h3>
            {connectors.length === 0 && !IS_LOCAL && (
              <p className="note">No injected wallet detected. Install a browser wallet (e.g. one supporting EIP-6963), then reload.</p>
            )}
            {connectors.map((c) => (
              <button key={c.uuid} className="wallet-opt" onClick={() => { connectInjected(c).then(onClose); }}>
                {c.icon && <img src={c.icon} alt="" />}
                <span>{c.name}</span>
              </button>
            ))}

            {IS_LOCAL && (
              <>
                <p className="note" style={{ marginTop: 8 }}>Local fork (chain 31337) — send via an unlocked anvil account:</p>
                {LOCAL_ACCOUNTS.map((a) => (
                  <button key={a} className="wallet-opt" onClick={() => { connectLocal(a); onClose(); }}>
                    <span className="mono">{shortAddr(a)}</span>
                  </button>
                ))}
              </>
            )}

            {WALLETCONNECT_PROJECT_ID && (
              <p className="note">WalletConnect project id is set but WalletConnect is not bundled in this build. See README.</p>
            )}
            {error && <div className="msg err">{error}</div>}
          </>
        )}
      </div>
    </div>
  );
}
