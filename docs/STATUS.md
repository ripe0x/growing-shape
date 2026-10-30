# Status

Updated 2026-10-30. **Audit-ready candidate, not deployed, not independently audited.** Candidate
revision for the contract: `a9f874e` (`src/` unchanged since `dcb9ce6`).

## Verified

Frozen-candidate run (`CANDIDATE_RUN=1 forge test`, revision `a9f874e`, pinned mainnet fork block
26,305,681, real Shapes, Draw Packs and FWA): **53 tests passed, 0 failed** across 9 suites.

| Suite | Tests | Covers |
| --- | ---: | --- |
| `test/fork/Primitives.t.sol` | 10 | FWA pool creation and permanent ownership, settlement and proceeds split, withdraw/compose/relist 0.5→1→5, locks while pending, expiry refunds, inventory version, purchase operator, pack minimum |
| `test/fork/Lifecycle.t.sol` | 11 | Launch, booking, decay publishing, first composition, featured win and restart, purchase gate, pack delivery, ladder parity |
| `test/fork/Growth.t.sol` | 6 | 0.5→1→5 then win and redeem 5 ETH, three cycles, notional monotonic, failed delivery booked then recovered, underfunded restart, retirement |
| `test/fork/Adversarial.t.sol` | 12 | Owner-only guards, every bound, owner extraction attempts, keeper reward caps and reentrancy, stray ETH/NFT, compose refused while a win is unbooked, growth pause |
| `test/fork/External.t.sol` | 4 | Slippage refund books nothing, 300 s cooldown, withdraw-only makes composition wait, purchases disabled |
| `test/fork/Gas.t.sol` | 1 | Gas for every player and keeper operation |
| `test/invariant/GameInvariants.t.sol` | 1 (3 invariants) | 64 runs × 64 calls = 4,096 random calls, 0 reverts: accounting identity, featured custody/price, counters, live-prize ↔ pool bijection |
| `test/review/fwa/Integration.t.sol` | 4 | Reviewer reproductions (FWA integration) |
| `test/review/custody/Custody.t.sol` | 4 | Reviewer reproductions (custody and accounting) |

Also: `keeper/test` 6 passed; `sim/test_model.py` all checks pass; `web` builds (`npm run build`).
Runtime size 24,038 B (EIP-170 margin 538 B).

Fork rehearsal (`script/rehearse.sh`, production parameters, real keeper in profit-seeking mode, dev
VRF, player bot): see [REPORT.md](REPORT.md#rehearsal). It found and drove three keeper fixes
(gas-starved FWA inner calls, unbounded log scans, `book` starving `replenish`).

## Not verified / limits

- No independent audit; two internal review agents only (AUDIT_SCOPE R1–R7).
- Web: injected-wallet (EIP-6963) path not run with a real extension; failed-delivery UI not driven
  live; WalletConnect not included.
- Sepolia: FWA's documented Sepolia stack differs from mainnet, so no testnet rehearsal.
- Simulation assumptions (prompt booking, no refunds) listed in ECONOMICS §2.

## Owner decisions (launch-blocking)

1. `RESIDUAL_RECIPIENT` (immutable; D2, R1).
2. Acquire 50,000 FWA for pool creation (D17).
3. Leftover growth fund after the final featured win at retirement (D12).
4. Accept draw price ≈ 0.0205 ETH all-in at 0.3 gwei with markup 110%, or lower markup to ~107.5%
   (ECONOMICS §3).

## Next action

Owner review of the decisions above, then commission an independent audit of `src/GrowingShape.sol` at
the candidate revision using docs/AUDIT_SCOPE.md.
