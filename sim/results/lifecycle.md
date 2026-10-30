# Lifecycle Monte Carlo (recommended config, 0.3 gwei, 500 draws/day)

4000 paths x 9000 delivered draws, seed 0.

| metric | value |
| --- | --- |
| P(featured won before first composition, at 0.5 ETH) | 9.0% |
| P(first featured reaches 1 ETH before won) | 91.0% |
| P(reaches 5 ETH before won) | 38.7% |
| P(reaches 10 ETH before won) | 23.6% |
| E[backing of winning featured] (ETH) | 2.951 |
| median draws to first composition (0.5->1) | 206 |
| median draws to reach 5 ETH | 1920 |
| median cycle length (draws to first win) | 1616 |
| keeper net ETH/draw (0.3 gwei, perDraw 0.0001) | -6.23e-05 |

## Backing at which featureds are won

| backing ETH | share of wins |
| --- | --- |
| 0.5 | 10.1% |
| 1.0 | 58.3% |
| 5.0 | 16.8% |
| 10.0 | 14.8% |

Days (at 500 draws/day): first composition ~0.4d, first win ~3.2d.
