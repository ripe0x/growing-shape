# Audit scope

## In scope

| File | Notes |
| --- | --- |
| `src/GrowingShape.sol` | The only deployed contract: custody, accounting, featured lifecycle, purchase gate, keeper pay. |
| `src/interfaces/IShapes.sol`, `IShapePacks.sol`, `IFWA.sol` | Subsets of deployed dependencies; signatures must match the verified sources. |
| `script/Params.sol`, `script/Addresses.sol`, `script/Deploy.s.sol` | Opening configuration, pinned addresses and code hashes, deployment and postflight checks. |

Out of scope: Shapes, Draw Packs and FWA themselves (deployed, separately reviewed), the keeper bot and
web app (unprivileged clients), simulations.

## Build

Solidity 0.8.30, `evm_version = prague`, via-IR, optimizer 200 runs, `bytecode_hash = none`,
`cbor_metadata = false`. Dependencies: solady v0.1.26 (`ReentrancyGuardTransient`, `SafeTransferLib`),
forge-std v1.16.2 (tests only).

## External dependencies and assumptions

See [SECURITY.md](SECURITY.md#trust-assumptions) and FUNCTIONAL_SPEC §3. Addresses and code hashes:
`deployments/dependencies.json`. Verified sources: Blockscout for the FWA factory, clone implementation
and VRF service (identical to the copies vendored in the public draw-shapes repository); Shapes and Draw
Packs from their public repositories.

## Questions for reviewers

1. Can any sequence of permissionless calls, FWA outcomes (expiry, slippage refund, failed delivery,
   staged and reserved listings) or Shapes behaviour make `book` consume a prize twice, skip one, or
   desynchronise `liveOrdinary`, tier weights or `inventoryCost` from the pool?
2. Can the owner, within the bounds, extract value directly or by playing (e.g. parameter changes,
   pausing, retirement timing)?
3. Is `canPurchase` always within FWA's 100k stipend, and can it be made to revert (which FWA treats as
   a denial)?
4. Can `compose` ever run on a featured listing that has been selected, or leave the token outside FWA?
5. Is keeper compensation drainable beyond `budgetCap` and per-draw accrual?
6. Does `finalize` release anything a player or the featured Shape is owed?

## Internal review findings

Two independent internal review agents (custody/accounting/authority, and FWA integration) reviewed
commit `8a73069` without the authors' threat model, wrote fork tests, and reported. Neither found a
critical or high issue. **This is internal review, not an independent audit.**

| ID | Severity | Finding | Resolution | Evidence |
| --- | --- | --- | --- | --- |
| R1 | Low | `RESIDUAL_RECIPIENT` may equal the owner; then retire + finalize returns working capital to the owner. Prizes, the featured Shape and the growth fund stay in play regardless. | Owner decision (D2), launch-blocking; Postflight prints it. Not enforced on-chain because ownership is transferable, so a check would not bind. | `test/review/custody/Custody.t.sol` |
| R2 | Low | `finalize` computed `operating − keeperBudget` and could revert when the allowance exceeded operating ETH. | Fixed: saturating subtraction. | `dcb9ce6` |
| R3 | Info | `startCycle` does not hold back the reserve target or keeper allowance. | By design: the seed is what `requiredLiquid` held back; the reserve stays. | — |
| R4 | Low-Med | `replenish` while a request is unsettled stages listings; `liveOrdinary` counts them before they are drawable. | Accepted: staged prizes are committed inventory that joins the draw FIFO through the next requests' reserved batches; bounded by 20 per call; depth floor has 30 draws of slack. | `test/review/fwa/Integration.t.sol` |
| R5 | Low | `startCycle`/`compose` could leave the featured listing Staged. | Fixed: when FWA is idle the game drains staging right after listing. When busy (only `startCycle`), it joins through reserved batches; the web app shows it as not yet drawable. | `dcb9ce6`, Integration test |
| R6 | Low | A draw booked while its delivery was pending earns no decay credit if delivery later succeeds. | Accepted (rare; errs toward slower decay; accounting unaffected). D13. | Integration test |
| R7 | Low | A Draw Pack tier below the deployed minimum would make `replenish` revert. | Fixed: `addTier` checks `PACKS.MIN_PACK_VALUE()`. | `dcb9ce6`, `test_tierBounds` |

Found by the lead during rehearsal: FWA's settlement delivery (150k-gas self-call) and the VRF service's
redelivery run as bounded inner calls that silently skip when the outer call is gas-starved. A caller
of FWA's permissionless `processAcquisitions` can therefore push a winner's delivery into FWA's 7-day
retry path. No value is at risk (retry is permissionless; after 7 days the purchaser can refund) and the
game cannot prevent it (FWA's function is public). The keeper now uses generous gas limits and retries
failed deliveries; the web app exposes retry.

Slither: triaged by the custody reviewer; only guarded reentrancy on trusted callees and benign
divide-before-multiply in the exact ladder decomposition.
