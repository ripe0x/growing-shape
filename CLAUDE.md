# Growing Shape

Onchain drawing game on Ethereum mainnet: one ETH-backed featured Shape grows by composition from
realised surplus while its FWA notional decays with play; ordinary Shapes and Draw Packs fill the rest
of an FWA V2 custom pool. Coinless by design.

## Where things are

- Behaviour: [docs/FUNCTIONAL_SPEC.md](docs/FUNCTIONAL_SPEC.md). Decisions and their alternatives:
  [docs/DECISIONS.md](docs/DECISIONS.md). Current state and next work: [docs/STATUS.md](docs/STATUS.md).
- Economics and chosen parameters: [docs/ECONOMICS.md](docs/ECONOMICS.md), reproducible from `sim/`.
- Trust, custody and invariants: [docs/SECURITY.md](docs/SECURITY.md). Audit package:
  [docs/AUDIT_SCOPE.md](docs/AUDIT_SCOPE.md). Deployment: [docs/DEPLOY.md](docs/DEPLOY.md).
- Contract: `src/GrowingShape.sol` (the only deployed contract). Interfaces to the real dependencies:
  `src/interfaces/`. Opening configuration: `script/Params.sol`. Mainnet addresses: `script/Addresses.sol`.
- Keeper bot and local VRF fulfiller: `keeper/`. Web app: `web/`. ABIs consumed by both: `abi/`
  (regenerate with `script/export-abi.sh`).

## Architecture principles

- One fixed custody contract. It is the permanent FWA pool owner and the only lister. No upgrade path,
  no module slots, no owner transfer of ETH or NFTs. Policy is bounded parameters; featured-Shape
  economics snapshot at each reset so changes apply to the next segment only.
- Reuse Shapes, Draw Packs and FWA as deployed. Players buy from the FWA pool directly; the game
  admits purchases through FWA's purchase-operator hook (`canPurchase`).
- Every maintenance step is permissionless and bounded; keepers are reimbursed from a capped allowance
  only for useful work. If keepers stop, purchases pause; player rights live in FWA and stay available.
- Accounting is explicit and reconciles exactly with the ETH balance (identity in `GrowingShape` NatSpec
  and `test/fork/GameBase.sol:_assertIdentity`). Growth comes only from the signed `surplus` ledger.

## Commands

```bash
forge build --sizes                                   # via-IR; GrowingShape must stay < 24,576 B
forge test --match-path test/fork/Lifecycle.t.sol     # one suite; fork tests need network the first time
cd keeper && npm test                                 # keeper decision logic
python3 -I sim/test_model.py                          # simulation self-check
./script/local.sh                                     # anvil fork (chain 31337) with the game launched
node keeper/dev-vrf.mjs                               # fulfil VRF on that fork
KEEPER_UNLOCKED=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC RPC_URL=http://127.0.0.1:8545 node keeper/keeper.mjs
```

Fork tests read `MAINNET_RPC_URL` (default `https://mainnet.gateway.tenderly.co`) and `FORK_BLOCK`
(default 26,305,681, pinned in `test/fork/ForkBase.sol`). Keep the block pinned so the RPC cache stays warm.
Whole-suite runs are reserved for a frozen release candidate (`CANDIDATE_RUN=1`); per change run the
affected files with `--match-path`.

## Conventions

- Solidity 0.8.30, `evm_version = prague`, via-IR, optimizer 200. Check runtime size after any change.
- Integration evidence comes from the pinned mainnet fork against the real contracts. Mocks only for
  isolated logic. Test actors are cleared of mainnet code (`GameBase.setUp`) because well-known test
  addresses carry EIP-7702 sweepers on mainnet.
- Comments carry rules, invariants and trust assumptions, not narration.
- No secrets in the repo. Keys come from the environment at runtime; local scripts use anvil's
  unlocked accounts.

## Continuing

Read `docs/STATUS.md` first: it lists what is verified, what is open, and the next action. Record
consequential choices in `docs/DECISIONS.md` and update the spec when evidence changes the design.
