import { useEffect, useState } from "react";
import type { Address, WalletClient } from "viem";
import { publicClient, canPurchase } from "../chain";
import { quoteDraw, sendDraw, DrawError } from "../draw";
import type { DrawQuote } from "../draw";
import { ethUnit } from "../format";
import { IS_LOCAL } from "../config";

const MAX_QTY = 5;

type Msg = { type: "ok" | "err" | "info"; text: string } | null;

export function DrawPanel(props: {
  pool: Address;
  account?: Address;
  walletClient?: WalletClient;
  paused: boolean;
  retired: boolean;
  wrongChain: boolean;
  block: bigint;
  onConnect: () => void;
  onDrawn: () => void;
}) {
  const { pool, account, walletClient, paused, retired, wrongChain, block, onConnect, onDrawn } = props;
  const [count, setCount] = useState(1);
  const [quote, setQuote] = useState<DrawQuote | null>(null);
  const [gateOpen, setGateOpen] = useState(false);
  const [sending, setSending] = useState(false);
  const [msg, setMsg] = useState<Msg>(null);

  // Keep the quote and purchase gate fresh as the user changes quantity or the chain advances.
  useEffect(() => {
    if (!account) {
      setQuote(null);
      setGateOpen(false);
      return;
    }
    let on = true;
    (async () => {
      try {
        const [q, allowed] = await Promise.all([quoteDraw(publicClient, pool, account, count), canPurchase(account)]);
        if (on) {
          setQuote(q);
          setGateOpen(allowed && !paused && !retired && !wrongChain);
        }
      } catch {
        if (on) setQuote(null);
      }
    })();
    return () => {
      on = false;
    };
  }, [account, count, pool, paused, retired, wrongChain, block]);

  const reason = retired
    ? "The game is retired."
    : wrongChain
      ? "Wrong network — switch your wallet."
      : paused
        ? "Draws are paused right now."
        : !gateOpen
          ? "Draws are closed right now (maintenance or composition in progress)."
          : null;

  async function onDraw(retry = false) {
    if (!account || !walletClient) return onConnect();
    setSending(true);
    if (!retry) setMsg({ type: "info", text: "Confirm in your wallet…" });
    try {
      const res = await sendDraw(publicClient, walletClient, pool, account, count, IS_LOCAL);
      setMsg({ type: "ok", text: `Drew ${res.requestIds.length || count}. Watch “Your draws” below for the outcome.` });
      onDrawn();
    } catch (e) {
      const de = e as DrawError;
      if (de.retryable && !retry) {
        setMsg({ type: "info", text: de.message });
        await onDraw(true);
        return;
      }
      setMsg({ type: "err", text: de.message || "The draw failed." });
    } finally {
      setSending(false);
    }
  }

  const price = quote?.total;
  const total = quote ? quote.total + quote.gasCost : undefined;
  const disabled = sending || (!!account && (!gateOpen || !quote));

  return (
    <div className="draw">
      <div className="qty">
        <span className="pill">Quantity</span>
        <div className="qty-steppers">
          <button type="button" aria-label="Fewer" disabled={count <= 1 || sending} onClick={() => setCount((c) => Math.max(1, c - 1))}>−</button>
          <span className="n mono" aria-live="polite">{count}</span>
          <button type="button" aria-label="More" disabled={count >= MAX_QTY || sending} onClick={() => setCount((c) => Math.min(MAX_QTY, c + 1))}>+</button>
        </div>
      </div>

      <div className="cost"><span className="muted">Draw price{count > 1 ? ` (${count})` : ""}</span><span className="mono">{price !== undefined ? ethUnit(price) : "—"}</span></div>
      <div className="cost"><span className="muted">Est. gas</span><span className="mono">{quote ? ethUnit(quote.gasCost) : "—"}</span></div>
      <div className="cost total"><span>Total cost</span><span className="mono">{total !== undefined ? ethUnit(total) : "—"}</span></div>

      <button className="btn-primary" type="button" disabled={disabled} onClick={() => onDraw()} style={{ marginTop: 12 }}>
        {!account ? "Connect wallet to draw" : sending ? <><span className="spin" /> Drawing…</> : `Draw ${count}`}
      </button>

      {account && reason && <div className="warn-banner">{reason}</div>}
      {msg && <div className={`msg ${msg.type}`}>{msg.text}</div>}
      <p className="note">Every successful draw delivers a real NFT. The VRF portion of the price is quoted with headroom; any overpayment is refunded to you.</p>
    </div>
  );
}
