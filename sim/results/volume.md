# Daily-volume sweep (recommended config)

Per-delivered-draw economics do not depend on volume; volume sets the calendar and the flat-reward burden (0.0002 ETH at most per 600s, which dominates at low volume).

| draws/day | days->1ETH | days->5ETH | days->first win | flat/draw ETH | flat vs perDraw |
| --- | --- | --- | --- | --- | --- |
| 20 | 10.2 | 95 | 77 | 0.000200 | 200.0% |
| 100 | 2.0 | 19 | 15 | 0.000200 | 200.0% |
| 500 | 0.4 | 4 | 3 | 0.000058 | 57.6% |
| 2000 | 0.1 | 1 | 1 | 0.000014 | 14.4% |

### Multi-week inactivity

No draws => no decay, no surplus, no keeper accrual; the board and featured simply wait. On resumption, play continues from the same state (FWA inventory version only bumps on list/reprice/withdraw, not on idling). Bursts up to 5 draws/tx and 10 outstanding requests/pool are absorbed by prompt booking; beyond maxPendingDraws(30) the gate pauses buying until the keeper books.
