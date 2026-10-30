# Deployment

Nothing here has been run against mainnet. Mainnet deployment needs the owner's explicit authorization.

## Prerequisites (owner)

1. `RESIDUAL_RECIPIENT` decided (D2). It is immutable.
2. Owner address (an EOA or contract the owner controls; there is no multisig requirement).
3. **50,000 FWA tokens** (the live `poolCreationFee`) available to send to the game (D17).
4. Opening capital (`Params.CAPITAL`, see ECONOMICS.md) plus gas for about 8 launch transactions
   (board listing is ~8.5–12.5M gas per batch of 20).
5. A keeper key funded with gas, and the keeper bot hosted somewhere reliable.

## Re-verify dependencies on the day

```bash
export R=https://mainnet.gateway.tenderly.co
cast call 0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c "implementation()(address)" --rpc-url $R
```

```bash
cast call 0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c "poolCreationFee()(uint256)" --rpc-url $R
```

```bash
cast call 0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0 "mintFee()(uint256)" --rpc-url $R
```

`Deploy.checkDependencies()` also enforces the factory and implementation code hashes, the token, the
pack minimum and the mint-fee range, and refuses to deploy if any changed. Compare the other live reads
with `deployments/dependencies.json`.

## Steps

1. **Deploy** (any funded deployer; the owner is a parameter):
   `GS_OWNER=… GS_RESIDUAL_RECIPIENT=… forge script script/Deploy.s.sol:Deploy --rpc-url $R --broadcast --account <keystore>`
   Writes `deployments/1.json`.
2. **Send 50,000 FWA** to the game address.
3. **Launch** (owner): `GS_GAME=… forge script script/Deploy.s.sol:Launch --rpc-url $R --broadcast --account <owner keystore>`.
   Opens the pool (pinned implementation, purchase operator = game, approvals), funds capital, lists the
   board in batches of 20 and lists the first featured Shape. Purchases remain paused.
4. **Postflight**: `GS_GAME=… GS_OWNER=… GS_RESIDUAL_RECIPIENT=… forge script script/Deploy.s.sol:Postflight --rpc-url $R`.
   Checks owner, recipient, dependencies, pool owner and operator, enabled acquisitions, full board,
   featured listed at its notional, reserve, and a fresh ledger.
5. **Start the keeper** (`keeper/README.md`), confirm it books and replenishes in dry-run mode.
6. **Unpause** (owner): `cast send <game> "setPaused(bool)" false`.
7. Verify source on Etherscan/Sourcify with the exact compiler settings in `foundry.toml`.

## Local rehearsal

`./script/local.sh` runs steps 1–4 and unpauses on an anvil mainnet fork (chain 31337) using anvil's
unlocked account and FWA tokens moved from the burn address on the fork only. `node keeper/dev-vrf.mjs`
stands in for Chainlink. The deploy script refuses any chain other than 1 and 31337.

## After launch

- Watch `canPurchase`, booking lag (`pool.lastIssuedSequence() − bookedSequence()`), `keeperBudget`,
  `operating()` vs `requiredLiquid()`, and FWA factory parameter changes.
- To end the game: `retire()`, then `finalize()` (see FUNCTIONAL_SPEC §10).
