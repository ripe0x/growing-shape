# Roadmap

Status markers: done, in progress, open.

## Phase 0. Verify primitives and architecture (done)
Acceptance: on a pinned mainnet fork, a pool is created and owned by its creator; a draw settles,
delivers and pays owner proceeds; the featured Shape is withdrawn, composed 0.5→1→5 with ID and seed
preserved, and relisted; repricing and withdrawal lock while a request is pending; expiry refunds;
inventory version invalidates stale quotes; the purchase operator gates; Draw Packs list.
Evidence: `test/fork/Primitives.t.sol` (10 tests). Live parameters: `deployments/dependencies.json`.

## Phase 1. Core: custody, pool, board, accounting, admission (done)
Acceptance: the game opens its own pool with a pinned implementation, lists a full board in batches,
books every settled request exactly once in sequence, collects proceeds, and the accounting identity holds
exactly; purchase admission refuses delivery-breaking purchasers and pauses on booking lag or thin board.
Evidence: `test/fork/Lifecycle.t.sol`.

## Phase 2. Featured lifecycle (done)
Acceptance: start, decay from delivered draws, stepped publishing only when idle, growth from surplus,
atomic composition with partial reset, win records and restart, underfunded restart with ordinary play.
Evidence: `test/fork/Lifecycle.t.sol`, `test/fork/Growth.t.sol`.

## Phase 3. Economic simulation (done)
Acceptance: reproducible Monte Carlo of the exact contract rules across the brief's §13 dimensions;
selected parameters in `script/Params.sol` with evidence in ECONOMICS.md; clear statement where growth
is not supportable. Evidence: `sim/`, docs/ECONOMICS.md (keeper allowance raised to 0.001 ETH per draw;
the game is sustainable below ~2 gwei).

## Phase 4. Permissionless operations and keeper (done)
Acceptance: every maintenance step permissionless and bounded; rewards only for work, capped by gas
price, interval and allowance; keeper bot plans, simulates and sends; outage pauses purchases without
touching player rights; local VRF fulfiller for the fork. Evidence: `test/fork/Adversarial.t.sol`,
`keeper/test`, local fork runs.

## Phase 5. Frontend (done; injected-wallet path not exercised with a real extension)
Acceptance: mobile-first app against the real contracts on the fork: live featured art and odds, quote
and draw 1–5 with full cost, pending → delivered, refunds and failed deliveries, verified cycle history. Evidence: `web/`, browser checks on the fork (mobile and
desktop, light and dark).

## Phase 6. Security review and hardening (done for internal review)
Acceptance: independent internal review agents on custody, accounting, FWA integration and economics;
stateful invariant fuzzing on the fork; static analysis; findings fixed and retested. Evidence:
AUDIT_SCOPE findings R1–R7, `test/review/`, `test/invariant/`.

## Phase 7. Deployment preparation and rehearsal (in progress)
Acceptance: `Deploy`, `Launch`, `Postflight` scripts with dependency checks; values-only configuration;
a full fork rehearsal through launch, several compositions and wins with no manual correction; operator
runbook. Evidence so far: `script/local.sh` launches and passes postflight on the fork.

## Phase 8. Audit package and final report (open)
Acceptance: AUDIT_SCOPE complete; verified results separated from assumptions; owner decisions and
launch blockers listed.
