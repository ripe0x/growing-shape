import type { GameState } from "../chain";
import { ethUnit, pct, eth } from "../format";

export function Prizes({ game }: { game: GameState }) {
  const approx = game.oddsExact ? "" : "~";
  return (
    <section className="section">
      <h2>Ordinary prizes</h2>
      <div className="card">
        {game.tiers.map((t) => (
          <div className="row" key={t.index}>
            <div className="left">
              <span className="title">{t.isPack ? "Draw Pack" : `Shape · ${eth(t.backing)} ETH`}</span>
              <span className="sub">{t.isPack ? `${t.packShapes} × 0.01 ETH Shapes (${eth(t.backing)} ETH)` : "ERC-721 with redeemable backing"}</span>
            </div>
            <div className="right">
              <div className="odds mono">{approx}{pct(t.chance)}</div>
              <div className="cnt">{t.live} live</div>
            </div>
          </div>
        ))}
      </div>
      <p className="note">
        Every successful draw awards a real NFT — a Shape or a Draw Pack. Odds are per draw. Redeeming any
        NFT for its backing ETH is a separate on-chain action and costs gas.
        {game.featured.active && <> The featured Shape ({ethUnit(game.featured.backing)}) is a {pct(game.featuredChance)} chance per draw.</>}
      </p>
    </section>
  );
}
