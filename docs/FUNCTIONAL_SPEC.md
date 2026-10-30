# Functional specification

Living specification. It started from the owner's implementation brief (2026-10-30) and records where
verified evidence changed it; each change cites a decision in [DECISIONS.md](DECISIONS.md).

## 1. Product

Growing Shape is a paid onchain drawing game on Ethereum mainnet (chain 1). A player pays ETH for a
verifiably random draw from one FWA V2 custom pool and receives a real NFT: an ETH-backed Shape or a
Draw Pack. One prize is special: the **featured Shape**. Realised surplus from play is composed into that
same token, so its redeemable backing steps up (0.5 → 1 → 5 → 10 → 50 → 100 ETH) while its token ID and
seed survive and its onchain artwork changes. Its FWA notional, which sets its selection weight, decays
with settled play and partially resets at each composition. Someone eventually draws it and receives the
token with all its backing and composition history, and a new cycle begins.

Scope is the coinless version: ETH, Shapes, Draw Packs and FWA only. No ERC-20, emissions, staking,
liquidity, buybacks, external NFT acquisition, depositors, multiple featured Shapes or governance system.

## 2. Components

| Component | Role |
| --- | --- |
| `GrowingShape` (`src/GrowingShape.sol`) | The only deployed contract. Owns the FWA pool forever, custodies ETH and in-transit NFTs, keeps the accounts, runs the featured lifecycle, gates purchases, pays keepers. |
| Shapes (mainnet `0x6fe9…6faf0`) | ERC-721 with exact ETH backing; `mintBatch`, `compose`, `redeem`. |
| Draw Packs (mainnet `0xf215…e5ca7`) | ERC-721 bundling Shapes; `createPack` mints its Shapes. Minimum pack value 0.03 ETH. |
| FWA V2 (factory `0xf5a3…300c`, clone implementation `0xeaa4…eb31`, VRF service `0xa4ad…5ee2`) | Escrow, inverse-notional weighted selection, Chainlink VRF v2.5 randomness, ordered settlement, delivery and refunds. |
| Keeper bot (`keeper/`) | Off-chain, unprivileged; simulates and sends maintenance calls. |
| Web app (`web/`) | Player interface reading chain state only. |

## 3. Verified external behaviour (block 26,305,681)

Shapes: mint pays backing + `mintFee` (0.001 ETH live, admin-settable up to 0.01) per Shape and uses
`_safeMint`; ladder 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 50, 100 ETH; `compose(survivor, burnIds)` requires the
caller to own every token (approval is not enough), the summed backing to be a ladder value, keeps the
survivor's ID and seed, moves no ETH; `redeem` pays exact backing to the caller. Transfers to the Shapes
contract itself revert.

Draw Packs: `createPack([], counts)` mints `counts[d]` Shapes of denomination `d` into a new pack and pays
one Shapes mint fee per Shape. `MIN_PACK_VALUE` is 0.03 ETH, so a 0.02 ETH pack cannot exist (D10).
`redeem` has Shapes pay the backing to the caller.

FWA: pool ownership is set to the creating address and can never change. Creation costs
`poolCreationFee` = 50,000 FWA tokens (burned) and one pool per creating address (`maxPoolsPerWallet` = 1,
beta gate off). Listing pulls the NFT with `transferFrom`; weight = 1e36 / notional. Draw fee =
harmonic-mean notional × (1 + `edgeBps`), edge 500 bps read live; the owner receives
`paid − (paid − base)/2` on delivery, the FWA protocol the rest. The VRF fee (1.5M gas × gas price × 1.3)
is paid separately to FWA's service. Requests settle strictly in sequence; withdrawal and repricing
revert while any request is unsettled; listing while unsettled stages instead of activating; every
inventory change bumps `inventoryVersion` (a buyer's pending transaction must match it exactly) and
restarts the factory cooldown (0 s live). Limits: 5 draws per transaction, 10 outstanding requests per
pool, 20 items per inventory batch, 30-block VRF deadline, ±10% settlement fee drift (negative side
buyer-set). Failed deliveries stay pending 7 days for permissionless retry, then the purchaser may take
a refund and the owner may recover the NFT. A word stored at the VRF service but not delivered can be
re-delivered by anyone (`deliverRandomness`). Exercised in `test/fork/Primitives.t.sol`.

## 4. Ordinary prizes

The board is up to 8 tiers. A tier is a Shape of 0.01, 0.05 or 0.1 ETH, or a Draw Pack of *n* 0.01 ETH
Shapes. Each tier has a target count (board total ≤ 240). Cost = backing + mint fees. Each ordinary
listing's notional is `cost × markupBps / 10,000` (markup ≥ 1.0, so no ordinary prize is player-positive
in expectation). `replenish(n)` mints and lists up to 20 missing prizes in tier order while operating ETH
allows, in one FWA inventory version. A markup change applies to prizes listed afterwards (D11).

## 5. The featured Shape

State: token ID, listing ID, backing, published notional, reset notional, decay per draw, floor, reset
share, compositions, draws credited since reset, draws this cycle, cost basis, seed cost, cycle number.

- **Start.** `startCycle()` mints the seed denomination (default 0.5 ETH) and lists it at
  `seed × startNotionalBps`. It needs operating ETH ≥ seed cost + every missing ordinary prize's cost.
- **Decay.** Each *delivered* ordinary draw while the featured Shape is listed credits one draw.
  `desired = max(floor, resetNotional − draws × decayPerDraw)` with `decayPerDraw = backing × decayPpm / 1e6`
  and `floor = backing × floorBps / 10,000`, both snapshotted at the latest reset (D4). Refunded, expired,
  failed-delivery or featured-winning draws credit nothing. The published FWA notional only ever falls
  between compositions, in steps: `publishDecay()` updates FWA when `desired` is one `repriceStepBps` below
  the published value or has reached the floor, and only when no request is unsettled (D6). Displayed odds
  always come from the published FWA listing.
- **Growth.** See §7. When the growth fund covers the next composition (next ladder value minus current,
  minted as the fewest Shapes, plus mint fees), `compositionDue()` is true and purchases pause.
- **Composition.** `compose()` runs atomically once no request is unsettled and every processed request
  is booked: withdraw the featured listing, mint the inputs, `Shapes.compose` into the same token, verify
  backing and custody, relist at `min(newBacking, desired + Δbacking × resetShareBps)`, re-snapshot decay
  parameters (D5, D7). Any failure reverts the whole call and leaves the Shape listed with its growth fund.
- **Win.** Booking a delivered (or delivery-pending) selection of the featured listing ends the cycle:
  a `CycleResult` (token, winner, backing, compositions, draws, blocks, request, cost basis) is stored and
  emitted, and the next cycle can start. Leftover growth carries over.

## 6. Purchases and admission

Players call FWA's `acquire`/`acquireBatch` directly. FWA calls `canPurchase(purchaser)` (100k gas). It
returns false when: the purchaser is the game, Shapes, Draw Packs or the pool (their deliveries would fail
or loop back into custody); the owner has paused (ignored after retirement); issued-but-unbooked draws
reach `maxPendingDraws`; worst-case board depth (live ordinary prizes minus unbooked draws) is below
`minLiveOrdinary` (ignored after retirement); a composition is due; or the published notional is at least
two reprice steps above `desired`. Ordinary draws continue between cycles.

## 7. Accounting

- `operating = balance − growthFund`. The game holds no player funds: draw fees, refunds and failed
  delivery escrow live in FWA.
- Ordinary inventory at cost (`inventoryCost`), featured cost basis, growth fund, keeper allowance
  (`keeperBudget`), replacement due (`replacementDue()`), cumulative `capitalIn`, `revenue`, `recovered`,
  `prizeExpense`, `featuredAwarded`, `keeperPaid`, `growthAllocated`, `drawsBooked`.
- **Identity** (exact absent forced ETH, asserted by every fork suite):
  `balance + inventoryCost + featuredCostBasis = capitalIn + revenue + recovered − prizeExpense − featuredAwarded − keeperPaid`.
- **Surplus** (signed, carries losses): + collected owner proceeds, + recovered redemptions, − cost of each
  ordinary prize won, − keeper pay, − growth allocated, − the seed cost of every featured Shape won
  (each cycle must earn back its seed). Capital never enters surplus.
- **Growth allocation** (on every `book`): `min(surplus, operating − requiredLiquid)` when both positive,
  with `requiredLiquid = reserveTarget + next seed cost + replacementDue + keeperBudget` (after retirement:
  `keeperBudget`). Solvency and playability come first.
- `book(n)` settles up to `n` processable FWA requests, books up to `n` processed requests in sequence
  order exactly once (a delivered or delivery-pending selection consumes its prize; expired and refunded
  ones book nothing), collects owner proceeds, and allocates growth.

## 8. Keepers

Permissionless: `book`, `replenish`, `startCycle`, `publishDecay`, `compose`, `recover`, `finalize`, plus
FWA's own `deliverRandomness`. Rewards: `(gasUsed + gasOverhead) × min(tx.gasprice, basefee + priorityCap,
gasPriceCap)` plus `flatReward` at most once per `flatInterval`, capped by `keeperBudget` and operating
ETH; nothing for calls that did no work. `keeperBudget` accrues `perDraw` per delivered draw up to
`budgetCap`; it is an allowance, not a separate balance, so unused budget stays operating capital.

## 9. Administration

One owner (two-step transfer) may, within hard bounds: set game parameters (markup 1.0–2.0×, start
notional 50–100%, floor 5–100%, reset share 20–100%, reprice step 1–50%, decay ≤ 5,000 ppm per draw,
pending cap 1–100, seed 0.1/0.5/1 ETH, reserve ≤ 20 ETH), keeper parameters (≤ 0.005 ETH per draw,
≤ 0.5 ETH cap, ≤ 0.002 ETH flat reward, interval ≥ 60 s, ≤ 200 gwei price cap, ≤ 10 gwei priority cap),
add tiers and change targets, pause purchases, pause compositions, open the pool once, and retire. No
owner path moves ETH or NFTs to anyone. Featured parameters apply from the next reset.

## 10. Retirement and migration

`retire()` is irreversible: no new prizes or cycles and no further owner changes; pause flags clear.
Every listed prize and the featured Shape stay winnable and keep decaying and composing. `finalize()`
(anyone) first adds surplus to growth while a featured Shape is listed, then sends operating ETH beyond
the keeper allowance to the immutable `RESIDUAL_RECIPIENT`; once nothing is listed or unsettled it retires
the FWA pool and sends every remaining wei. There is no in-place upgrade: a successor is a new deployment
with its own pool and capital (D2). Who `RESIDUAL_RECIPIENT` is remains a launch-blocking owner decision.

## 11. Frontend

Mobile-first single primary view of the featured Shape's onchain artwork with backing, chance per draw,
published notional, progress to next composition, compositions, draws this cycle, draw price and full
transaction cost, and a draw action; the ordinary prizes with odds; the connected wallet's draws,
outcomes, refunds and failed deliveries with their actions; completed cycles verified from chain. No
fake activity, placeholder winners or invented probabilities.

## 12. Changes from the original brief

| Brief | Now | Why |
| --- | --- | --- |
| 0.02 ETH Draw Packs | 0.03 ETH packs (3 × 0.01) | Deployed `MIN_PACK_VALUE` is 0.03 ETH (D10). |
| Linear decay, unit open | Per delivered draw, scaled to backing | Fixed absolute decay leaves large Shapes nearly unwinnable (D4). |
| Adjustable markup applied to the board | Applies to newly listed prizes | Contract-size limit removed the reprice path (D11). |
| Retirement with orderly settlement | Prizes stay winnable; free capital released; no forced drain | Avoids any owner path to listed prizes (D12). |
| Pool creation unspecified | 50,000 FWA tokens supplied by the operator | Live factory fee (D17). |
