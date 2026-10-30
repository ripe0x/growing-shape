import { parseEther } from "viem";
import type { Address, WalletClient } from "viem";
import type { GameState } from "../chain";
import { Art } from "../Art";
import { DrawPanel } from "./DrawPanel";
import { ethUnit, pct, eth } from "../format";

// Backing ladder the featured Shape climbs as surplus composes into it.
const LADDER = [0.5, 1, 5, 10, 50, 100].map((v) => ({ eth: v, wei: parseEther(String(v)) }));

export function Featured(props: {
  game: GameState;
  account?: Address;
  walletClient?: WalletClient;
  wrongChain: boolean;
  onConnect: () => void;
  onDrawn: () => void;
}) {
  const { game, account, walletClient, wrongChain, onConnect, onDrawn } = props;
  const f = game.featured;
  // FWA notional is authoritative from the live listing weight: weight = 1e36 / notional.
  const notional = f.weight > 0n ? 10n ** 36n / f.weight : f.notional;
  const progress = game.compositionCost > 0n ? Number((game.growthFund * 1000n) / game.compositionCost) / 1000 : 0;
  const currentStep = LADDER.findIndex((s) => s.wei === f.backing);

  return (
    <section className="section" aria-label="Featured Shape">
      {f.listed || f.won ? (
        <Art collection={game.shapes} tokenId={f.tokenId} alt={`Featured Shape #${f.tokenId}`} />
      ) : (
        <div className="art-frame"><div className="art--empty">Next featured Shape being prepared</div></div>
      )}

      {f.listed && (
        <>
          <div className="stats">
            <div className="stat"><div className="k">Backing (redeemable)</div><div className="v mono">{ethUnit(f.backing)}</div></div>
            <div className="stat"><div className="k">Chance per draw</div><div className="v mono">{f.active ? pct(game.featuredChance) : "—"}</div></div>
            <div className="stat"><div className="k">FWA notional</div><div className="v mono">{eth(notional)} <small>ETH</small></div></div>
            <div className="stat"><div className="k">Compositions</div><div className="v mono">{f.compositions}</div></div>
            <div className="stat"><div className="k">Draws this cycle</div><div className="v mono">{f.cycleDraws}</div></div>
            <div className="stat"><div className="k">Shape #</div><div className="v mono">{f.tokenId.toString()}</div></div>
          </div>

          <div className="progress">
            <div className="label">
              <span>{game.compositionDue ? "Ready to compose" : "Toward next composition"}</span>
              <span className="mono">{eth(game.growthFund)} / {eth(game.compositionCost)} ETH</span>
            </div>
            <div className="track"><div className="fill" style={{ width: `${Math.min(100, Math.max(2, progress * 100))}%` }} /></div>
          </div>

          <div className="ladder" aria-label="Backing ladder">
            {LADDER.map((s, i) => (
              <span key={s.eth} className={`step ${i === currentStep ? "on" : i < currentStep ? "past" : ""}`}>{s.eth} ETH</span>
            ))}
          </div>
        </>
      )}

      {f.won && (
        <p className="note" style={{ textAlign: "center" }}>
          Featured Shape #{f.tokenId.toString()} was just won ({ethUnit(f.backing)} backing). The next featured Shape is being prepared. Ordinary draws continue.
        </p>
      )}
      {!f.listed && !f.won && (
        <p className="note" style={{ textAlign: "center" }}>
          Between cycles, ordinary draws continue. A new featured Shape will be listed shortly.
        </p>
      )}

      <DrawPanel
        pool={game.pool}
        account={account}
        walletClient={walletClient}
        paused={game.paused}
        retired={game.retired}
        wrongChain={wrongChain}
        block={game.block}
        onConnect={onConnect}
        onDrawn={onDrawn}
      />
    </section>
  );
}
