# Growing Shape — economic simulation

Exact-rules Monte Carlo over `src/GrowingShape.sol`. One step = one delivered draw,
vectorised across independent game paths with numpy. Results feed `docs/ECONOMICS.md`.

Python 3.11, numpy + scipy, no matplotlib/pandas. **Always run with `python3 -I`** (the
scripts add their own directory to `sys.path` so `-I` imports work).

## Files

- `model.py` — the engine. `Config`/`GameParams`/`KeeperParams`/`Tier` mirror
  `script/Params.sol`. `simulate(cfg, ...)` runs the per-draw loop; the closed-form
  helpers (`board_H`, `owner_proceeds`, `select_probs`, `all_in_price`,
  `keeper_gas_per_draw`, `growth_allocation`, `composition_cost`) are the deterministic
  pieces and are unit-tested. Every departure from the contract is flagged `# assume:`.
- `run.py` — named, seeded sweeps that write `results/*.md` (+ `.json`, + one `.csv`).
- `test_model.py` — plain-assert self-checks against hand-computed values, incl. the
  contract accounting identity.
- `results/` — generated outputs (committed so the doc tables are reproducible).

## Reproduce

```sh
python3 -I sim/test_model.py                 # self-checks -> "all ok"
python3 -I sim/model.py                       # smoke: board analytics + tiny sim
python3 -I sim/run.py all --seed 0            # every sweep (~1.5 min)
python3 -I sim/run.py static price keeper     # fast analytic tables (<1 s)
python3 -I sim/run.py lifecycle --paths 6000 --draws 10000 --seed 7
```

Each sweep and what it answers:

| sweep | output | question |
| --- | --- | --- |
| `static` | results/static.md | H, fee, proceeds, net surplus/draw, P(featured) by stage, draws per composition |
| `price` | results/price.md | all-in draw price by markup × gas (single & batch-5) |
| `keeper` | results/keeper.md | keeper gas/draw, net ETH/draw & break-even gas by perDraw; flat-reward burden |
| `lifecycle` | results/lifecycle.md (+ _timeseries.csv) | P(win before comp), P(reach 1/5/10), E[win backing], draws/days |
| `params` | results/params.md | markup / decayPpm / floor / resetShare / startNotional sweeps |
| `board` | results/board.md | board compositions (packs, 0.01 count, depth) and seed denomination |
| `volume` | results/volume.md | days-to-stage and keeper flat-reward burden at 20/100/500/2000 draws/day |
| `longrun` | results/longrun.md | reach 50/100 and repeated wins over a long horizon |

Seeds are fixed (`--seed`, default 0). `--paths` / `--draws` override MC size. Default
MC sizes keep every sweep to a few minutes at most.

## Model shape in one paragraph

Each delivered draw: compute the active board's harmonic base `H`, credit owner proceeds
`1.025·H` to revenue/surplus/balance; accrue the keeper budget; pick the won listing by
weight `1e36/notional`; expense an ordinary prize (and re-mint it) or award the featured
(and charge back its seed, then restart); sweep `min(surplus, operating−requiredLiquid)`
to the growth fund; compose the featured one rung up as soon as the fund covers the cost;
credit backing-scaled decay and republish in steps; reimburse the keeper from its budget
at `min(gasprice, 20 gwei)`. The accounting identity from `docs/SECURITY.md` holds to
<1e-6 ETH on every path, which is the model's leak check.
