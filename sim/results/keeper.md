# Keeper sustainability

Steady maintenance load ~= 541k execution gas / delivered draw (dominated by replenishing the won prize; ~78% of wins are 0.01 Shapes at 426k gas each).

Contract caps perDraw at 0.001 ETH and the reimbursed price at min(gasprice, 20 gwei). Net ETH/draw = perDraw - gas_per_draw * eff_price. Negative => keeper loses money and stops.

| perDraw | break-even gwei | net @0.3gwei | net @1gwei | net @3gwei | net @10gwei | net @30gwei |
| --- | --- | --- | --- | --- | --- | --- |
| 0.0001 | 0.18 | -6.23e-05 | -4.41e-04 | -1.52e-03 | -5.31e-03 | -1.07e-02 |
| 0.0003 | 0.55 | +1.38e-04 | -2.41e-04 | -1.32e-03 | -5.11e-03 | -1.05e-02 |
| 0.0005 | 0.92 | +3.38e-04 | -4.12e-05 | -1.12e-03 | -4.91e-03 | -1.03e-02 |
| 0.0010 | 1.85 | +8.38e-04 | +4.59e-04 | -6.23e-04 | -4.41e-03 | -9.82e-03 |

Break-even gas at the MAX allowed perDraw (0.001): **1.85 gwei**. Above this, no allowed perDraw keeps the keeper solvent even though realized surplus (~0.0024 ETH/draw) could pay many times the gas.

## Flat-reward burden by volume (0.0002 ETH at most per 600s)

| draws/day | sec/draw | flat reward/draw | vs 0.0001 accrual |
| --- | --- | --- | --- |
| 20 | 4320 | 0.000200 | 200.0% |
| 100 | 864 | 0.000200 | 200.0% |
| 500 | 173 | 0.000058 | 57.6% |
| 2000 | 43 | 0.000014 | 14.4% |
