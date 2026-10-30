# Status

Updated 2026-10-30. Exploration-to-verified-slice stage. Not deployed. Not audited.

## Verified (pinned mainnet fork, block 26,305,681, real Shapes, Draw Packs and FWA)

| Suite | Tests | Covers |
| --- | ---: | --- |
| `test/fork/Primitives.t.sol` | 10 | FWA pool creation and permanent ownership, settlement and proceeds split, withdraw/compose/relist 0.5→1→5, locks while pending, expiry refunds, inventory version, purchase operator, pack minimum |
| `test/fork/Lifecycle.t.sol` | 11 | Launch, booking, decay publishing, first composition, featured win and restart, purchase gate (composition due, booking lag, blocked purchasers), pack delivery, ladder parity |
| `test/fork/Growth.t.sol` | 6 | 0.5→1→5 then win and redeem 5 ETH, three cycles, notional monotonic between compositions, failed delivery booked and recovered, underfunded restart, retirement |
| `test/fork/Adversarial.t.sol` | 12 | Owner-only guards, every parameter bound, owner extraction attempts, keeper reward caps and reentrancy, stray ETH/NFT rejection, compose refused while a win is unbooked, growth pause |
| `test/fork/Gas.t.sol` | 1 | Gas for every player and keeper operation |
| `keeper/test` | 6 | Keeper job planning and reward estimate |

Each fork suite asserts the exact accounting identity. Runtime size 23,682 B (limit 24,576 B).
Local fork: `script/local.sh` deploys, launches and passes postflight; dev VRF fulfiller and keeper
bot booked and replenished live.

## In progress

- Economic simulation (`sim/`, ECONOMICS.md): parameter selection. `script/Params.sol` holds provisional
  values (markup 1.10, decay 377 ppm, floor 10%, reset 70%, capital 4.2 ETH).
- Frontend (`web/`).

## Open

- Phase 6: independent review agents, stateful invariant fuzzing on the fork, static analysis.
- Phase 7: full fork rehearsal of several growth and win cycles through the scripts and keeper.
- Keeper sizing at realistic gas (budget per draw likely too low at ≥ 1 gwei; pending simulation).
- Owner decisions (launch-blocking): `RESIDUAL_RECIPIENT`; acquiring 50,000 FWA for pool creation;
  leftover growth at final retirement.

## Next action

Apply the simulation's recommended parameters to `script/Params.sol`, re-run the affected fork suites,
then start Phase 6 reviews.
