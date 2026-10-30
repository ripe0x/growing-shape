# Security

## Custody

`GrowingShape` holds operating ETH, the growth fund, and NFTs only while minting or composing within one
transaction. Listed prizes sit in FWA escrow under a pool the game owns permanently. Player money is never
held by the game: draw fees, refunds and failed-delivery escrow live in FWA, and VRF fees go to FWA's VRF
service.

ETH leaves the game only to: Shapes and Draw Packs mints (prizes, seeds, composition inputs, all minted
to the game itself); keeper reimbursement (capped, from an allowance); `RESIDUAL_RECIPIENT` after
retirement. NFTs leave only into the FWA pool (listing), into `Shapes.compose` (burned inputs), or into
redemption (recovered failed deliveries). No function takes a destination address from the caller.

## Permissions

| Actor | Can | Cannot |
| --- | --- | --- |
| Owner | Bounded game and keeper parameters, tiers, pause purchases, pause compositions, open the pool once, retire, transfer ownership (two-step) | Move ETH or NFTs; change pool, collections, implementation pin or residual recipient; change the live featured schedule; act after retirement |
| Anyone (keeper) | `book`, `replenish`, `startCycle`, `publishDecay`, `compose`, `recover`, `finalize`, `fund` | Choose recipients or amounts; earn without work |
| Player | Buy draws from FWA; retry or refund failed deliveries; withdraw FWA refunds | Purchase as the game, Shapes, Packs or the pool |

## Trust assumptions

- **FWA factory owner** (`0x0198…E8Cb`) can, live: change `edgeBps` (draw price and protocol share),
  `inventoryChangeCooldown`, global purchase and withdraw-only switches, VRF pausing, the protocol fee
  recipient, and rotate the implementation for *new* pools. The game pins the reviewed implementation at
  `openPool`. A cooldown would interrupt purchases after each listing change; withdraw-only would block
  relisting, so compositions would wait. The game reads these live and fails closed.
- **FWA VRF service and Chainlink VRF v2.5** provide randomness. A missed callback expires the request
  (refund, no prize consumed). The service owner can pause requests.
- **Shapes admin** can change the mint fee (cap 0.01 ETH), renderer and metadata. A higher fee raises
  replacement and composition costs, which the game reads live. Shapes holds every prize's backing.
- **Draw Packs admin** reaches presentation only.
- **Keepers** are untrusted. Their worst case is not acting: purchases pause; player rights in FWA stay.
- **Owner** is trusted only for liveness and policy within bounds. Residual capital destination is fixed
  at deployment.

## Invariants (tested)

1. Accounting identity: `balance + inventoryCost + featuredCostBasis = capitalIn + revenue + recovered −
   prizeExpense − featuredAwarded − keeperPaid`, exact absent forced ETH (`_assertIdentity` in every fork
   suite).
2. Each FWA request is booked once, in sequence; only a selected listing consumes a prize, exactly once
   (`prizes[listingId].live` gate).
3. Expired or refunded draws produce no revenue and no decay credit.
4. Growth only from positive `surplus` and only above `requiredLiquid`; capital never enters `surplus`.
5. The featured token ID and seed survive every composition; backing equals the ladder value after each.
6. The published featured notional never rises between compositions.
7. Composition and repricing never run while a request is unsettled or a processed request is unbooked,
   so a featured Shape already won is never touched.
8. No owner function moves ETH or NFTs; every parameter is bounded.

## Known risks and limitations

- Contract-size headroom is ~0.9 KB; fixes must stay small.
- High gas makes replacement expensive (~0.43M gas per Shape, ~0.8M per pack); see ECONOMICS.md.
- Purchases pause while a composition is due or booking lags. Under very heavy demand the pause can
  recur.
- Forced ETH (selfdestruct) becomes operating capital; it cannot become surplus.
- A future gas-schedule change could make FWA's 150k-gas delivery stipend fail for Shapes transfers;
  deliveries would then go through FWA's retry and refund paths (D13).
- Anyone can call FWA's `processAcquisitions` with a gas-starved transaction so a winner's NFT delivery
  fails and enters FWA's retry window (see AUDIT_SCOPE). Recovery is permissionless; the keeper retries.
- Replacements listed while a request is unsettled are staged and briefly not drawable but are counted in
  `liveOrdinary` (R4).
- Internal review only. No independent audit has been performed.
