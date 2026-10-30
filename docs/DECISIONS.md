# Decisions

Each entry: the choice, the alternatives considered, and the consequence. Owner-review items are
marked **Owner decision**.

## D1. One fixed custody contract that owns the FWA pool
`GrowingShape` creates the FWA pool itself, so it is the pool's permanent owner and sole lister, and it
holds every ETH balance and in-transit NFT. Alternatives: a vault plus policy modules, or a proxy. Both
add an authority that can redirect custody. Consequence: one audit target; all policy is bounded
parameters inside it; contract size is the binding constraint (23.7 KB of 24.6 KB).

## D2. No upgrade path; migration is retire and redeploy
FWA pool ownership is permanent and the factory allows one pool per creating address, so a successor
cannot take over this pool. A migration function that sends assets to an owner-named successor would
be an owner withdrawal with extra steps; a timelock does not change that. Chosen: no upgrade, no
migration function. A successor is a new deployment; this one retires (D12). **Owner decision:** who
`RESIDUAL_RECIPIENT` (immutable) is. If it is the founder, retirement returns unneeded working capital;
if it is a successor game, the founder must deploy that first. Launch-blocking.

## D3. Players buy directly from FWA; the game admits purchases through the purchase operator
Players call FWA's `acquire` so the game adds no gas or custody to a draw. The game is the pool's
`purchaseOperator`; `canPurchase` encodes every pause condition as a view over state, so no pause flag can
get stuck. Alternative: route purchases through the game (adds ~100k gas and makes the game hold player
ETH). Consequence: purchase admission costs ~50k gas inside FWA's 100k stipend.

## D4. Decay per delivered draw, scaled to backing
`desired = max(floor, reset − draws × backing × decayPpm / 1e6)`. The credit unit is the delivered draw,
not ETH turnover: draws are what players see, and the draw price is stable, so the two are nearly
equivalent. A fixed absolute decay was rejected after simulation: at 5–50 ETH it takes tens of thousands
of draws to move the odds, leaving large Shapes effectively unwinnable. Scaling by backing keeps the odds
moving at every size and makes the floor (a share of backing) the long-run hazard.

## D5. Partial reset at composition
`newNotional = min(newBacking, desired + Δbacking × resetShareBps)` using the decayed `desired` (not the
stepped published value), so decay already earned is never lost to step granularity. Default 70%;
simulation evidence in ECONOMICS.md.

## D6. Published decay in steps; stale decay pauses purchases
FWA reprices only with no request unsettled, and each reprice bumps the inventory version, invalidating
in-flight buyer transactions. Publishing per draw would collide with buyers constantly. Chosen: publish
at one `repriceStepBps` (5%) or at the floor; if the published value is two steps stale, `canPurchase`
pauses so an idle window arrives. Displayed odds always use the published listing.

## D7. Atomic composition
Withdraw, mint, compose, verify and relist in one transaction once FWA is idle and fully booked. No
intermediate custody state exists between transactions, so there is nothing to recover from an
interrupted composition. The only resumable state is "composition due", which is derived, and pauses
purchases until the keeper composes. `setGrowthPaused` exists so the owner can reopen purchases if
composing becomes impossible (for example a Shapes change); growth keeps accumulating meanwhile.

## D8. Growth only from the surplus ledger, after reserves
Signed `surplus` carries losses; capital never enters it; each won featured Shape's seed is charged to
it, so every cycle must earn back its seed before more growth. Allocation needs operating ETH above
reserve + next seed + missing prizes + keeper allowance. Alternative: a revenue split per draw. Rejected
because a split funds growth even while the game is losing money.

## D9. Featured parameters snapshot at each reset
Decay rate, floor and reset share are copied into the featured state at cycle start and at every
composition. The owner cannot change the odds of the Shape currently in play; changes take effect at
the next reset. This closes "tune decay, then snipe" extraction.

## D10. 0.03 ETH Draw Packs instead of 0.02
The deployed Draw Packs contract reverts below 0.03 ETH. Packs are three 0.01 ETH Shapes (cost 0.033 ETH).
The simulation decides whether packs belong on the board at all (they cost ~800k gas to replace).

## D11. Ordinary markup applies to newly listed prizes
A permissionless `repriceOrdinary` was removed to fit EIP-170. After a markup change, the board converges
as prizes are won and replaced; rarely won tiers keep the old price longer. Acceptable because markup
changes are rare and bounded at ≥ 1.0× cost.

## D12. Retirement keeps prizes in play
`retire()` stops new prizes and cycles and freezes administration. Every listed prize and the featured
Shape stay winnable, so retirement can never return a listed prize to the owner. `finalize()` releases
only operating ETH not needed for keepers (after adding surplus to growth while a featured Shape is
listed); everything else follows once the board is empty. An earlier design withdrew unwon inventory
after a 90-day grace; dropped because it is an owner path to the prizes and the code did not fit.
**Owner decision:** leftover growth fund after the final featured Shape is won goes to
`RESIDUAL_RECIPIENT`; an alternative is converting it into final ordinary prizes (not implemented).

## D13. Failed deliveries are consumed at booking
A selected prize whose delivery is pending or refunded has left the pool, so booking consumes it (no
decay credit). If the purchaser later refunds, `recover()` pulls the NFT back and redeems it; the ETH
re-enters `surplus` as `recovered`. Purchasers that would make delivery fail (the game, Shapes, Packs,
the pool) are refused at purchase.

## D14. Keeper compensation
Measured gas at a capped price plus an interval-limited flat reward, from an allowance that accrues per
delivered draw and is capped; no reward for no work; no age-based bounty. The allowance is not a separate
balance. Sizing is in ECONOMICS.md; at high gas, keepers batch (booking many draws per call).

## D15. Code-size choices
via-IR, a minimal two-step owner instead of a library, launch by unpausing (acquisitions enabled at
`openPool`, `paused` set at construction), arithmetic ladder lookup. Runtime 23,682 B.

## D16. Settlement folded into `book`
`book(n)` first calls FWA `processAcquisitions(n)` so one rewarded keeper call settles expiries,
reserved batches and failed fast paths, then books. FWA's VRF callback still settles most requests itself.

## D17. Pool creation fee
The live factory charges 50,000 FWA tokens per pool, pulled from the creating address. The operator must
send that amount to the game before `openPool`. **Owner decision:** acquiring the FWA tokens is a launch
prerequisite and an external purchase this project has not made.

## D18. Booking lag and depth guards
`maxPendingDraws` bounds how far play can run ahead of accounting; `minLiveOrdinary` keeps the worst-case
board deep enough that FWA settlement-time fee drift stays inside its ±10% tolerance. Both pause purchases
rather than risk refunds or an unaccounted board.
