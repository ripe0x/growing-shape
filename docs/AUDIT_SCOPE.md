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

## Findings

Internal review has not started (Phase 6). Findings and their resolution will be listed here.
