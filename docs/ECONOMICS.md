# Growing Shape — Economics

Status: reviewed by the lead engineer 2026-10-30; recommendations applied (keeper `perDraw` 0.001 ETH,
`budgetCap` 0.1 ETH, contract bound on `perDraw` raised from 0.001 to 0.005 ETH so the owner can extend
keeper liveness toward ~4 gwei if needed). Earlier status: draft for review. Owner of this file and `sim/`: the economic model. The
contract rules it models are owned by the lead engineer; where the model implies a
contract change, it is called out, not applied.

All numbers come from `sim/` (exact-rules Monte Carlo over `src/GrowingShape.sol`).
Reproduce any table with the command named beside it; see `sim/README.md`.

---

## 1. Headline

**The game works and grows observably at today's gas, but two things need a decision before launch:**

1. **Keeper budget is too small.** Keeping the board full costs **~541k gas per delivered
   draw** (mostly re-minting the won Shape). At the current `perDraw = 0.0001 ETH` the keeper
   is **net-negative at any gas above ~0.18 gwei** — i.e. already underwater at today's
   ~0.26 gwei basefee. Raising `perDraw` to the contract maximum `0.001 ETH` fixes it up to
   **~1.85 gwei**. Above ~1.85 gwei the original bound allowed no working value; the bound is now
   0.005 ETH, so the owner can raise `perDraw` toward ~4 gwei liveness at the cost of growth. Above
   **~4.35 gwei** keeper gas exceeds the game's entire surplus, so growth is impossible regardless and
   sustained play at that gas spends capital on replacement. See §6. **Growing Shape is a
   sub-~2-gwei game.**

2. **All-in draw price sits right at the 0.02 ETH target, not below it.** At markup 110% and
   0.3 gwei the fee alone is 0.0198 ETH; with VRF and player gas the all-in is **0.0205 ETH**.
   Getting strictly ≤0.02 means markup ≈107.5% (0.0201) or a pack-free board (0.0153), each
   with a growth cost. See §3.

Everything else is healthy: **net surplus ≈ 0.00235 ETH/draw**, first composition in
**~205 draws**, median featured win in **~1,600 draws**, and winners take home a Shape worth
**~2.9 ETH on average** (10% at 0.5, 58% at 1, 17% at 5, 15% at 10).

---

## 2. Model and assumptions

### Verified against the contract / mainnet source (facts)

> 1. **FWA fee.** Acquisition fee `= H·(1+edge)`, `H = N/Σ(1/pᵢ)` (harmonic mean of active
>    notionals), edge 500 bps. Owner proceeds per *delivered* draw `= paid−(paid−H)/2 = 1.025·H`;
>    protocol keeps `0.025·H`. Fee is the same whatever listing is selected.
> 2. **Selection.** Listing `i` is won with probability `wᵢ/Σw`, `wᵢ = 1e36/pᵢ`. Confirmed by
>    `GameBase._wordFor` (word % totalWeight over cumulative weight).
> 3. **Launch board.** 50×0.01 + 35×0.03 pack + 10×0.05 + 4×0.1 + 1 featured; `inventoryCost =
>    2.619 ETH`, featured seed 0.5 ETH, start notional 0.5 ETH (asserted in `Lifecycle.t.sol`).
> 4. **Decay.** Per *delivered* draw, `decayPerDraw = backing·decayPpm/1e6`, linear from the
>    reset notional, floored at `backing·floorBps`. Published in steps (`repriceStepBps`).
> 5. **Composition.** Next ladder step; cost `= Δbacking + count·mintFee`. 0.5→1 = 0.501,
>    1→5 = 4.004, 5→10 = 5.001, 10→50 = 40.004, 50→100 = 50.001 ETH.
> 6. **Ledger & waterfall.** Signed `surplus` (+proceeds, −prize cost, −seed on win, −keeper,
>    −growth). Growth booking `= min(surplus, operating − requiredLiquid)`, `requiredLiquid =
>    reserve + seed + mintFee + replacementDue + keeperBudget`. **Capital never becomes surplus.**
> 7. **Accounting identity** `balance + inventoryCost + featuredCostBasis == capital + revenue +
>    recovered − prizeExpense − featuredAwarded − keeperPaid` holds in the model to < 1e-6 ETH
>    across every path (`test_model.py::test_accounting_identity`), which is the model's proof
>    that it leaks no ETH.
> 8. **Measured gas** (mainnet fork, from the brief): acquire(1) 609k, acquireBatch(5) 1.66M,
>    VRF callback 529k (paid by the VRF fee), book 270–330k, replenish 426k/Shape & 800k/pack,
>    publishDecay 100–150k, compose 0.8–1.19M, startCycle 754k.

### Assumptions (simplifications; each flagged `# assume:` in `sim/model.py`)

> 1. **Prompt booking.** In-flight (acquired-but-unbooked) listings do not shrink the active
>    weight set. True only while the keeper books promptly; pending is capped at 30 of ~100, so
>    the effect on `H` and P(featured) is ≤ a few percent.
> 2. **Published ≈ desired within one step.** The keeper publishes each decay step, so the
>    2-step-stale purchase pause never fires. Selection uses the published notional (≤5% stale).
> 3. **No refunds.** Expiry (30 blocks w/o VRF) and settlement fee-drift refunds are assumed
>    rare under prompt VRF. They cost a player gas but never touch game economics; player
>    refund risk is discussed in §3, not in the core loop.
> 4. **Keeper books in batches of 20** (amortises the 30k/call overhead). Replenish gas is
>    charged per won prize; booking is amortised ~47k/draw.
> 5. **One composition step per draw** — growth rises ~0.0024 ETH/draw, never enough to skip a
>    rung in a single draw.
> 6. **gasprice ≈ basefee** for the keeper's reimbursement cap `min(gasprice, basefee+1, 20)`.

The economics are **per delivered draw and volume-independent by construction**; daily volume
only sets the calendar and the keeper flat-reward burden (§5).

---

## 3. Draw price (target: ≤ 0.02 ETH all-in at low gas)

`python3 -I sim/run.py price static`

The FWA fee is **gas-independent**; VRF (1.95M·gasprice) and player tx gas add the rest.

| markup | fee | all-in @0.3 gwei (1 / batch-5) | @1 gwei | @3 gwei |
| --- | --- | --- | --- | --- |
| 105.0% | 0.01887 | 0.01964 / 0.01955 | 0.02145 | 0.02663 |
| **110.0% (rec.)** | **0.01976** | **0.02054 / 0.02045** | 0.02235 | 0.02753 |
| 120.0% | 0.02156 | 0.02234 / 0.02225 | 0.02415 | 0.02932 |

Component split at markup 110%, single acquire: fee 0.01976 + VRF + player gas =
**0.0205 (0.3 gwei) · 0.0224 (1 gwei) · 0.0275 (3 gwei) · 0.0456 (10 gwei)**.

**Read:** at markup 110% the all-in is 0.0205 ETH at 0.3 gwei — ~2.5% over the soft 0.02 target,
and essentially *all* of that budget is the fee. Strictly ≤0.02 is only reachable at ultra-low
gas *and* markup ≲107.5% (0.0201) or by dropping the 0.03 packs (0.0153). Above ~1 gwei the
target is unreachable at any markup because VRF+gas alone add ≥0.0026 ETH.

---

## 4. Surplus, growth and lifecycle

`python3 -I sim/run.py static lifecycle longrun`

Per-draw economics at the launch board (markup 110%): **proceeds 0.01929 − E[prize cost]
0.01694 = net surplus 0.00235 ETH/draw** (pre-keeper). This matches the lead's mean-field
exactly.

Draws to fund each composition (all net surplus to growth):

| step | cost ETH | draws (step) | cumulative draws from seed |
| --- | --- | --- | --- |
| 0.5→1 | 0.501 | 213 | 213 |
| 1→5 | 4.004 | 1,702 | 1,915 |
| 5→10 | 5.001 | 2,125 | 4,040 |
| 10→50 | 40.004 | 17,002 | 21,042 |
| 50→100 | 50.001 | 21,251 | 42,294 |

Monte Carlo lifecycle (4,000 paths × 9,000 draws, 0.3 gwei, 500 draws/day):

| metric | value |
| --- | --- |
| P(won before first composition, at 0.5 ETH) | **9%** |
| P(first featured reaches 1 / 5 / 10 ETH before won) | **91% / 39% / 24%** |
| E[backing of winning featured] | **2.95 ETH** |
| win backing distribution | 10% @0.5, 58% @1, 17% @5, 15% @10 |
| median draws to first composition | **206** (~0.4 d @500/day) |
| median cycle length (draws to first win) | **1,616** (~3.2 d @500/day) |
| mean featured wins per path (60k draws) | 9.5 |

Long-run reach of the *first* featured: P(reach 50) ≈ **1%**, P(reach 100) ≈ **0.7%**. Reaching
50/100 needs the featured to survive uncomposed-by-win across 21k–42k draws; it is a rare,
multi-year-at-realistic-volume outcome, by design.

**Read:** the "growing" mechanic is genuinely observable — most featureds are won at 1 ETH,
a quarter reach 10, and the race between decaying odds and accumulating backing is live at
every rung. 50 and 100 are aspirational, not routine.

---

## 5. Daily volume and inactivity

`python3 -I sim/run.py volume`

| draws/day | days→1 ETH | days→5 ETH | days→first win | keeper flat reward/draw | vs 0.0001 accrual |
| --- | --- | --- | --- | --- | --- |
| 20 | 10.2 | 95 | 77 | 0.000200 | 200% |
| 100 | 2.0 | 19 | 15 | 0.000200 | 200% |
| 500 | 0.4 | 4 | 3 | 0.000058 | 58% |
| 2000 | 0.1 | 1 | 1 | 0.000014 | 14% |

Inactivity is safe: no draws → no decay, no surplus, no keeper accrual; the board and featured
simply wait and resume from the same state (FWA inventory version only bumps on
list/reprice/withdraw). Bursts up to 5 draws/tx and 10 outstanding requests/pool are absorbed by
prompt booking; beyond `maxPendingDraws` (30) the gate pauses buying until the keeper books.

**The flat reward (0.0002 ETH / 600 s) dominates keeper cost at low volume** — at ≤100 draws/day
every booking is >600 s apart, so the keeper claims 0.0002/draw, which is 2× the default accrual
on its own.

---

## 6. Keeper sustainability (the decision)

`python3 -I sim/run.py keeper`

Steady maintenance ≈ **541k execution gas/draw**: ~78% of wins are 0.01 Shapes re-minted at
426k gas each, ~18% packs at 800k, plus ~47k/draw booking. This is intrinsic to re-minting
on-chain Shapes and cannot be lowered without changing the board or the contract.

Net ETH/draw `= perDraw − 541k·eff_price`, `eff_price = min(gasprice, 20 gwei)`:

| perDraw | break-even gwei | @0.3 | @1 | @3 | @10 |
| --- | --- | --- | --- | --- | --- |
| 0.0001 (current) | 0.18 | −6.2e-5 | −4.4e-4 | −1.5e-3 | −5.3e-3 |
| 0.0005 | 0.92 | +3.4e-4 | −4.1e-5 | −1.1e-3 | −4.9e-3 |
| **0.0010 (max)** | **1.85** | +8.4e-4 | +4.6e-4 | −6.2e-4 | −4.4e-3 |

Three regimes:

> 1. **≤ 1.85 gwei** — fixed entirely by `perDraw = 0.001` (within the current contract bound).
>    Surplus (0.00235/draw) dwarfs the gas, so the keeper is paid in full with margin.
> 2. **1.85 – 4.35 gwei** — surplus still covers the gas, but the contract's `perDraw ≤ 0.001`
>    bound throttles reimbursement below cost. **Only a contract change (raise the bound) helps.**
> 3. **> 4.35 gwei** — keeper gas exceeds the *entire* surplus; the game cannot both keep the
>    board full and grow. It should pause; players also stop buying here (all-in > 0.028 ETH),
>    so this is self-correcting — Growing Shape is a low-gas game that idles through gas spikes.

At the current ~0.26 gwei basefee the default `perDraw = 0.0001` is already ~40% short
(net −4.1e-5/draw). **Raising it to 0.001 is required, not optional.**

---

## 7. Parameter & board sweeps (alternatives)

`python3 -I sim/run.py params board`

- **Markup** is the master lever: it trades price against growth linearly. 105% → all-in 0.0196
  but P(reach 5) only 6.5% and E[win] 1.11 ETH (growth barely visible); 120% → all-in 0.0223 but
  P(reach 5) 67% and E[win] 5.4 ETH. **110% is the balance** (0.0205, P(reach 5) 38%, E[win] 2.5).
- **decayPpm** sets how fast odds recover toward the floor: 200 → P(reach 5) 53%, 1500 → 6%.
  377 keeps wins spread across rungs.
- **floorBps / resetShareBps** mostly reshape *where* in the ladder wins land; higher resetShare
  (90%) lifts P(reach 5) to 46%.
- **startNotionalBps** 100% starts the featured hardest-to-win; lowering to 50% raises
  P(won at 0.5) to 17% (more "quick small wins", fewer growers).
- **Board.** Dropping the 0.03 packs makes draws much cheaper (0.0153 all-in) and lowers funding
  (2.85 ETH) but halves growth (P(reach 5) 18.5%) and removes the Draw Pack product. A
  pack-and-0.01-heavy board (80×0.01) lands at 0.0183 all-in with P(reach 5) 33% — a reasonable
  "cheaper draws" alternative if hitting ≤0.02 matters more than the current growth rate.
- **Seed denomination.** 0.1 → cheap, fast small wins (29% won at seed, E[win] 1.3); 1.0 →
  needs more capital and most wins land at 1 ETH. **0.5 gives the best spread** (§4).

---

## 8. Recommended opening configuration

`script/Params.sol` — change only the keeper block; everything else is already well-chosen.

```
GameParams:  markupBps 11_000, startNotionalBps 10_000, floorBps 1_000,
             resetShareBps 7_000, repriceStepBps 500, decayPpm 377,
             minLiveOrdinary 60, maxPendingDraws 30, seedIndex 3, reserveTarget 0.5 ether
KeeperParams: perDraw 0.001 ether  (was 0.0001),  budgetCap 0.1 ether (was 0.05),
             flatReward 0.0002 ether, flatInterval 600, gasOverhead 30_000,
             gasPriceCap 20 gwei, priorityCap 1 gwei
Tiers:       unchanged (50×0.01, 35×0.03 pack, 10×0.05, 4×0.1)
CAPITAL:     4.2 ether
```

Rationale, value by value:

> - **markupBps 11_000** — all-in 0.0205 ETH at today's gas (fee is the whole budget), net
>   surplus 0.00235/draw, first composition ~205 draws, growth visible at every rung. Lower only
>   if ≤0.02 all-in is a hard requirement (use 10_750 → 0.0201, accepting ~20% slower growth).
> - **seedIndex 3 (0.5 ETH)** — best win-backing spread; 0.1 makes the game feel like a lottery
>   of tiny Shapes, 1.0 needs more capital for the same effect.
> - **startNotionalBps 10_000, floorBps 1_000, decayPpm 377, resetShareBps 7_000** — produce the
>   §4 distribution; they are confirmed good and I would not change them for launch.
> - **reserveTarget 0.5 + CAPITAL 4.2** — launch spends 2.619 (board) + 0.501 (seed) = 3.12,
>   leaving 1.08 operating against 1.0 held back. Adequate, but tight; see risk (3) below.
> - **perDraw 0.001 (↑10×)** — the one required change. Makes keeping profitable to ~1.85 gwei;
>   `perDraw` is a flow rate and holds back no extra capital.
> - **budgetCap 0.1 (↑2×)** — a larger spike buffer (~18 draws of 10-gwei gas vs ~9 before).
>   Holds back 0.1 ETH of operating via `requiredLiquid`; acceptable against 4.2 capital. Keep at
>   0.05 if preserving the reserve matters more than spike tolerance.

**Alternatives worth a conscious choice:** markup 10_750 for a ≤0.02 all-in; a pack-free or
0.01-heavy board for cheaper draws at the cost of growth; `CAPITAL 5.0–5.5` for a thicker launch
reserve.

---

## 9. Remaining economic risks

> 1. **Keeper unprofitable above ~1.85 gwei (contract-bounded), impossible above ~4.35 gwei
>    (economic).** Mitigation: raise the `perDraw` bound in `_setKeeperParams` (contract change;
>    surplus covers gas to ~4.3 gwei), or accept that the game idles through gas spikes. This is
>    the single most important open item. See §6 and the final report.
> 2. **All-in price is at, not below, the 0.02 target**, and rises steeply with gas (0.046 at
>    10 gwei). The game is only attractively priced at sub-1-gwei gas.
> 3. **Launch reserve is thin (0.08 ETH headroom).** A cluster of expensive (0.1 ETH) early wins
>    before revenue accumulates could briefly stall replenishment. 4.2 ETH works in simulation;
>    5.0+ would be comfortable.
> 4. **10→50 and 50→100 are multi-year at realistic volume** (17k / 21k draws of growth each).
>    The ladder steps are fixed by Shapes, so the only lever is the growth rate (markup). Not a
>    bug — just set expectations.
> 5. **Model assumptions (§2)** — prompt booking, no refunds, published≈desired. All second-order
>    under an active keeper, but a neglected or unprofitable keeper breaks all three at once
>    (booking lags → active set shrinks → `H` and odds drift → purchases pause). Risk (1) and the
>    assumptions are the same risk.

---

## 10. Contract-level findings (for the lead)

> 1. **`_setKeeperParams` caps `perDraw` at 0.001 ETH, but steady maintenance is ~541k gas/draw.**
>    At `eff_price` above ~1.85 gwei no allowed `perDraw` reimburses the keeper, so booking and
>    replenishment stall and `canPurchase` pauses buying — even though realized surplus
>    (~0.0024 ETH/draw) could pay the gas up to ~4.35 gwei. Evidence: `sim/results/keeper.md`.
>    Suggested fix: raise the `perDraw` bound (e.g. to 0.005 ETH) so reimbursement can track gas
>    out to the point where surplus itself runs out. This is a single comparison-constant change in
>    `_setKeeperParams` with negligible bytecode impact (runtime is 23,682 B of the 24,576 B limit).
> 2. **Replenishment cost is the binding constraint, and it scales with the cheapest tier.**
>    Because 0.01 Shapes carry the most selection weight (78% of wins) yet cost the same 426k gas
>    to re-mint as any Shape, the board "churns" ~332k gas/draw just recycling 0.011 ETH prizes.
>    Any future gas optimisation of Shapes minting, or a lazier replenish path, moves the
>    sustainability ceiling the most.
> 3. **No economic bug in the waterfall or seed-recovery logic.** The signed-surplus waterfall,
>    per-cycle seed charge, and growth carry-over behave correctly and conserve ETH exactly
>    (identity test). Underfunded restarts did not occur at 4.2 ETH capital in any simulated path.
