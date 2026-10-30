# Static board economics (recommended config)

Board: [(0.01, 50), (0.03, 35), (0.05, 10), (0.1, 4)], markup 110%, featured seed 0.5 ETH.

| metric | value (ETH) |
| --- | --- |
| harmonic base H | 0.018823 |
| acquisition fee (1.05 H) | 0.019764 |
| owner proceeds / delivered draw (1.025 H) | 0.019293 |
| E[prize cost] / draw | 0.016941 |
| net surplus / draw (pre-keeper) | 0.002353 |
| P(featured won)/draw at seed notional | 3.76e-04 |

## P(win featured) per draw by stage

| backing | floor notional | P/draw @reset | P/draw @floor | 1/P @reset | 1/P @floor |
| --- | --- | --- | --- | --- | --- |
| 0.5 | 0.05 | 3.76e-04 | 3.75e-03 | 2,656 | 267 |
| 1 | 0.1 | 1.88e-04 | 1.88e-03 | 5,312 | 532 |
| 5 | 0.5 | 3.77e-05 | 3.76e-04 | 26,554 | 2,656 |
| 10 | 1 | 1.88e-05 | 1.88e-04 | 53,108 | 5,312 |
| 50 | 5 | 3.77e-06 | 3.77e-05 | 265,535 | 26,554 |
| 100 | 10 | 1.88e-06 | 1.88e-05 | 531,069 | 53,108 |

## Expected draws to fund each composition (growth at net surplus/draw)

| step | cost ETH | cumulative ETH | draws (step) | draws (cumulative from seed) |
| --- | --- | --- | --- | --- |
| 0.5->1 | 0.501 | 0.501 | 213 | 213 |
| 1->5 | 4.004 | 4.505 | 1,702 | 1,915 |
| 5->10 | 5.001 | 9.506 | 2,125 | 4,040 |
| 10->50 | 40.004 | 49.510 | 17,002 | 21,042 |
| 50->100 | 50.001 | 99.511 | 21,251 | 42,294 |
