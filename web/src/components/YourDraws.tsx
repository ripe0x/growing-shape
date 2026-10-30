import { useState } from "react";
import type { Address, WalletClient } from "viem";
import type { OutcomesResult, Outcome } from "../chain";
import { publicClient } from "../chain";
import { poolAbi } from "../abi";
import { sendWrite } from "../draw";
import { Art } from "../Art";
import { ethUnit, shortAddr } from "../format";

const LABEL: Record<Outcome["kind"], string> = {
  pending: "Pending",
  delivering: "Delivering",
  delivered: "Delivered",
  refunded: "Refunded",
  failed: "Delivery failed",
};

export function YourDraws(props: {
  pool: Address;
  account: Address;
  walletClient?: WalletClient;
  data: OutcomesResult | null;
  onChanged: () => void;
}) {
  const { pool, account, walletClient, data, onChanged } = props;
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string>();

  async function act(key: string, fn: string, args: unknown[]) {
    if (!walletClient) return;
    setBusy(key);
    setErr(undefined);
    try {
      await sendWrite(publicClient, walletClient, pool, poolAbi, fn, args, account);
      onChanged();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Action failed.");
    } finally {
      setBusy(null);
    }
  }

  const outcomes = data?.outcomes ?? [];
  const refund = data?.refundCredit ?? 0n;

  return (
    <section className="section">
      <h2>Your draws</h2>

      {refund > 0n && (
        <div className="bar">
          <span>Refund available: <strong className="mono">{ethUnit(refund)}</strong></span>
          <button className="btn btn-ghost" disabled={busy === "refund"} onClick={() => act("refund", "withdrawAcquisitionRefund", [])}>
            {busy === "refund" ? <span className="spin" /> : "Withdraw"}
          </button>
        </div>
      )}

      {err && <div className="msg err">{err}</div>}

      <div className="card">
        {outcomes.length === 0 ? (
          <div className="center-muted">No draws yet from {shortAddr(account)}.</div>
        ) : (
          outcomes.map((o) => (
            <div className="outcome" key={o.requestId.toString()}>
              {(o.kind === "delivered" || o.kind === "failed") && o.collection && o.tokenId !== undefined ? (
                <div className="thumb"><Art collection={o.collection} tokenId={o.tokenId} isPack={o.isPack} alt={`Prize #${o.tokenId}`} /></div>
              ) : (
                <div className="thumb"><div className="art-frame"><div className="art--empty" /></div></div>
              )}
              <div className="meta">
                <div className="what">
                  {o.tokenId !== undefined && (o.kind === "delivered" || o.kind === "failed")
                    ? `${o.isPack ? "Draw Pack" : "Shape"} #${o.tokenId}`
                    : o.kind === "refunded" ? "Refunded draw" : "Draw"}
                </div>
                <div className="req">req {shortAddr(`0x${o.requestId.toString(16)}`)}</div>
                {o.kind === "failed" && (
                  <div style={{ marginTop: 6, display: "flex", gap: 6 }}>
                    <button className="btn btn-ghost" disabled={busy === `retry${o.listingId}`} onClick={() => act(`retry${o.listingId}`, "retryNFTDelivery", [o.listingId])}>Retry delivery</button>
                    <button className="btn btn-ghost" disabled={busy === `rf${o.listingId}`} onClick={() => act(`rf${o.listingId}`, "refundFailedDelivery", [o.listingId])}>Refund</button>
                  </div>
                )}
              </div>
              <span className={`badge ${o.kind}`}>{LABEL[o.kind]}</span>
            </div>
          ))
        )}
      </div>
      {outcomes.some((o) => o.kind === "delivered") && (
        <p className="note">Delivered NFTs are in your wallet. Redeeming one for its backing ETH is a separate transaction and costs gas.</p>
      )}
    </section>
  );
}
