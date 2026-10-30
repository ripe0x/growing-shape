# Growing Shape — web app

Minimal, mobile-first web client for the Growing Shape onchain drawing game.
Players pay ETH for a verifiably random draw from an FWA V2 custom pool; every
successful draw delivers a real NFT, and surplus grows one **featured Shape**
until someone wins it. The UI is centred on the featured Shape's actual onchain
artwork and reads everything from chain — no invented activity, winners, or odds.

## Stack

- **React 19 + TypeScript**, bundled with **Vite 7**.
- **viem** for all chain access (reads via Multicall3 batching, logs, `simulateContract`, wallet sends).
- No wallet framework: injected wallets are discovered with **EIP-6963**; a dev-only
  local mode sends through anvil's unlocked accounts. No other runtime dependencies.

Exact pinned versions: `react`/`react-dom` 19.3.1, `viem` 2.57.7, `vite` 7.3.7,
`@vitejs/plugin-react` 5.0.4, `typescript` 5.9.3, `@types/react(-dom)` 19.3.0.

## Configure

Copy `.env.example` to `.env` (or `.env.local`) and set:

| Var | Meaning |
| --- | --- |
| `VITE_RPC_URL` | JSON-RPC endpoint. Mainnet default: `https://mainnet.gateway.tenderly.co`. |
| `VITE_CHAIN_ID` | `1` for mainnet, `31337` for the local anvil fork (enables local-account mode). |
| `VITE_GAME_ADDRESS` | `GrowingShape` address (local value from `deployments/31337.json`; mainnet value at launch). |
| `VITE_DEPLOY_BLOCK` | Game deployment block; bounds all `getLogs` ranges. |
| `VITE_WALLETCONNECT_PROJECT_ID` | Optional, off by default (see below). |

Env vars are read at build time, so **rebuild after changing them**.

## Run (local fork)

The repo's local fork must be up first (from the repo root):

```sh
./script/local.sh          # anvil mainnet fork on :8545, deploys + unpauses the game
node keeper/dev-vrf.mjs &   # fulfils VRF locally (logs to dev-vrf.log)
```

Then, in `web/`:

```sh
npm install
npm run dev     # http://localhost:5173
```

The default `.env` already points at the local fork. In the header click
**Connect** → pick a local anvil account to send draws through it.

## Build

```sh
npm run build   # tsc --noEmit && vite build -> dist/
npm run preview # serve the production build
```

`dist/` uses relative asset paths (`base: "./"`), so it can be served from any
sub-path (static host, IPFS, CDN folder).

## Production wallets

Production uses injected wallets only: EIP-6963 discovery plus EIP-1193. The
local-account mode is gated to `chainId === 31337`.

**WalletConnect is intentionally not bundled.** It requires a project id we don't
have, and pulling in its SDK would add a large dependency tree. `VITE_WALLETCONNECT_PROJECT_ID`
is reserved: if set, the connect sheet notes WalletConnect isn't available in this
build. To wire it, add a WalletConnect EIP-1193 provider and surface it as another
connector in `src/wallet.ts` / `src/components/Connect.tsx`.

## How it works (map)

- `src/config.ts` — env + constants (Multicall3, poll interval, explorer, local accounts).
- `src/abi.ts` — vendored ABIs from `abi/*.json`, plus added fragments: Shapes/Packs
  `tokenURI`/`svg`/`ownerOf`, and the FWA custom-error names (absent from the
  interface ABI) so reverts decode to human text.
- `src/chain.ts` — viem clients, `readGame`, `readOutcomes`, `readHistory`, art decoding.
  Concurrent reads auto-batch into one Multicall3 call (`batch.multicall`).
- `src/draw.ts` — quote (VRF priced at 2× the send gas price for headroom; overpay is
  refunded), `simulateContract`, send, requestId parsing, and error translation.
- `src/hooks.ts` — 12s polling with imperative refresh after a transaction.
- `src/components/*` — Featured (hero art + stats + composition progress + draw panel),
  Prizes, YourDraws (pending / delivered-with-art / refund / failed-delivery actions), History.

### Odds

Per draw, `listingProbability = weight / pool.totalWeight()`. The featured weight is
read from the live pool listing (`weight = 1e36 / notional`), and the featured is
treated as **won / not drawable** whenever its listing status isn't Active/Staged —
`featured().listingId` stays nonzero after a win until the keeper books the next cycle.
Tier odds are `tier.weight / totalWeight`, shown with a `~` only when staged listings
make the live weights not sum to `totalWeight`.

### Draw payment

The VRF portion of the quote depends on `tx.gasprice`, so the quote is taken via
`eth_call` at 2× the current gas price; `value` is sent with that headroom and any
overpayment is refunded on-chain. `maxAcquisitionFee` = quoted fee,
`maxNegativeSlippageBps` = 1000, `expectedInventoryVersion` = `inventoryVersion()`
(an `InventoryVersionMismatch` auto-re-quotes and retries once), deadline ≈ 10 min.
In local mode the send pins a cheap legacy `gasPrice`; injected wallets choose their own.
