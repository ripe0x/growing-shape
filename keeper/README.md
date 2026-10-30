# Keeper

An unprivileged bot that keeps Growing Shape playable. Each tick it reads the game and its FWA pool,
plans the useful jobs (`keeper/lib.mjs`), simulates each call, and sends the highest-priority one whose
reimbursement covers its gas. It re-plans after every transaction.

Jobs, in priority order: re-deliver a VRF word the FWA service stored but could not deliver
(`deliverRandomness`, unrewarded), `book` (settle, book, collect, allocate growth), `replenish`,
`startCycle`, `compose`, `publishDecay`.

## Run

```bash
cd keeper && npm ci
```

```bash
RPC_URL=https://mainnet.gateway.tenderly.co GAME=0x… DRY_RUN=1 node keeper.mjs
```

```bash
RPC_URL=https://mainnet.gateway.tenderly.co GAME=0x… KEEPER_PRIVATE_KEY=… node keeper.mjs
```

The key is read from the environment at start and never logged or written. Prefer a dedicated key
holding only gas money. Options: `INTERVAL_MS` (15000), `MAX_GAS_PRICE_GWEI` (50, defer above),
`KEEPER_ALTRUISTIC=1` (send even when the reward is below cost, for operators who want liveness
regardless), `BOOK_BATCH` (50), `ONCE=1`.

## Local fork

```bash
./script/local.sh && node keeper/dev-vrf.mjs &
KEEPER_UNLOCKED=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC RPC_URL=http://127.0.0.1:8545 node keeper/keeper.mjs
```

`dev-vrf.mjs` fulfils requests through the real coordinator → service path by impersonating the
Chainlink coordinator; it refuses any chain but 31337. `DEV_VRF_DROP=0.2` drops a share of requests to
exercise expiry.

## Tests

`npm test` runs the job-planning and reward checks.

## Economics

A profit-seeking keeper batches: booking one draw at 1 gwei costs about 0.0004 ETH, so it waits until
enough draws accrue budget. `canPurchase` pauses buying at `maxPendingDraws` unbooked draws, which
bounds that wait. Sizing is in `docs/ECONOMICS.md`.
