# Growing Shape: implementation report

Repository: https://github.com/ripe0x/growing-shape (public, MIT). Candidate contract revision
`a9f874e`. Nothing is deployed. No independent audit has been performed.

## 1. What was built

| Part | Where | State |
| --- | --- | --- |
| Game contract (custody, accounting, featured lifecycle, purchase gate, keeper pay) | `src/GrowingShape.sol` | Candidate; 24,038 B runtime |
| Interfaces to deployed Shapes, Draw Packs, FWA V2 | `src/interfaces/` | Verified against source and bytecode |
| Opening configuration, addresses, deploy/launch/postflight | `script/` | Fork-rehearsed |
| Economic model and results | `sim/`, `docs/ECONOMICS.md` | Reproducible |
| Keeper bot, local VRF fulfiller, player bot, state report | `keeper/` | Rehearsed on a fork |
| Web app | `web/` | Built; checked in a browser against forks |
| Spec, decisions, security, deploy, audit scope, status | `docs/`, `CLAUDE.md` | Current |

## 2. Architecture

One contract, `GrowingShape`, creates and permanently owns its FWA V2 custom pool. It mints prizes into
itself, lists them in batches, and never sends an NFT anywhere except into the pool, into
`Shapes.compose`, or into redemption. Players buy directly from FWA; FWA asks `GrowingShape.canPurchase`
before taking payment, which pauses buying when maintenance is needed. The featured Shape is composed
atomically (withdraw → mint → compose → verify → relist) only when FWA is idle and every settled request
is booked. Accounting is a signed surplus ledger plus an exact balance identity. There is no upgrade path;
a successor is a new deployment (D2). Full description: [FUNCTIONAL_SPEC.md](FUNCTIONAL_SPEC.md).

## 3. Chosen economic configuration

Markup 110% of cost; board 50 × 0.01 Shape, 35 × 0.03 Draw Pack, 10 × 0.05, 4 × 0.1; featured seed 0.5
ETH at 100% notional; decay 377 ppm of backing per settled draw to a 10% floor, published in 5% steps;
70% partial reset; reserve 0.5 ETH; keeper allowance 0.001 ETH per draw (cap 0.1); opening capital
4.2 ETH. Evidence and alternatives: [ECONOMICS.md](ECONOMICS.md).

Key results (simulation, 0.3 gwei): all-in draw **0.0205 ETH** (fee 0.0198); net surplus 0.00235 ETH per
draw; first composition ~205 draws; median featured win ~1,600 draws; P(reach 5 ETH) 39%, 10 ETH 24%,
50 ETH 1%; mean winning backing ~2.9 ETH. **The game is sustainable below ~2 gwei**; above ~4.35 gwei
keeper gas exceeds the entire surplus.

## 4. Verification

Frozen candidate `a9f874e`, `CANDIDATE_RUN=1 forge test` on a pinned mainnet fork against the real
contracts: **53 passed, 0 failed** (details in [STATUS.md](STATUS.md)). Includes a stateful invariant
campaign of 4,096 random calls. Keeper unit tests 6/6; simulation self-check passes; web build passes.

Gas (fork, execution gas): player `acquire(1)` 609k, `acquireBatch(5)` 1.66M; keeper `book` 0.27–0.48M;
`replenish` ~0.43M per Shape and ~0.8M per pack (7.8–8.5M per 20); `compose` 1→5 1.19M; `startCycle`
0.75M; `canPurchase` ~50k inside FWA's 100k stipend.

## 5. Security

Invariants and trust assumptions: [SECURITY.md](SECURITY.md). Two independent internal review agents
(custody/accounting, FWA integration) found no critical or high issue; seven low/info findings, three
fixed, the rest accepted with reasons: [AUDIT_SCOPE.md](AUDIT_SCOPE.md#internal-review-findings).
Adversarial tests cover every owner lever and direct pool call (no extraction path), keeper reward caps
and reentrancy, stray ETH/NFTs, composing a won Shape, FWA governance changes, slippage refunds and
failed deliveries.

## 6. Keeper

[keeper/README.md](../keeper/README.md). Unprivileged; plans jobs from live state, simulates, sends only
when reimbursed (or always, in altruistic mode), uses generous gas limits because FWA's inner delivery
calls skip silently on short gas, retries failed deliveries, and sends each job type once per round so
booking cannot starve replenishment.

## 7. Rehearsal

`script/rehearse.sh`: production parameters on a chain-31337 mainnet fork; Deploy → Launch → Postflight →
unpause through the real scripts, then the keeper (profit-seeking), the dev VRF fulfiller and a player bot.

Results are recorded in [§7.1](#71-results). The run used one-block VRF latency, which is far faster than
mainnet (FWA's 10-request cap and ~36 s VRF latency bound play to ~0.25 draws/s per pool), so it doubles
as a stress test. It surfaced three keeper defects, all fixed: gas-starved FWA inner calls, unbounded log
scans on a fork, and `book` starving `replenish`. Under the starvation bug the board sank to the
`minLiveOrdinary` floor and `canPurchase` paused buying until it recovered, which is the intended failure
mode.

### 7.1 Results

Pending at the time of writing; see the final message of the implementation session and
`rehearsal/report.json` when re-run.

## 8. Owner decisions and launch blockers

1. **`RESIDUAL_RECIPIENT`** (immutable). If it is the owner, retiring returns unneeded working capital to
   the owner; prizes, the featured Shape and its growth fund stay in play either way.
2. **50,000 FWA tokens** for pool creation.
3. **Leftover growth fund** after the final featured win at retirement: residual recipient (current) or
   converted into final prizes (not implemented).
4. **Price target**: accept 0.0205 ETH all-in at 0.3 gwei (markup 110%) or lower markup to ~107.5%
   (0.0201, ~20% slower growth).
5. Independent security audit and legal review before any deployment.

## 9. Assumptions versus verified facts

Verified on chain: every dependency address, code hash, live parameter and behaviour in FUNCTIONAL_SPEC
§3. Assumed: Chainlink VRF liveness; FWA factory governance acting in good faith (it can halt purchases or
raise the edge); mainnet gas staying mostly below ~2 gwei; player demand. Not exercised: a real browser
wallet extension, Sepolia (FWA's Sepolia stack differs from mainnet).
