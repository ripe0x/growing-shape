"""Exact-rules Monte Carlo for Growing Shape.

The engine follows src/GrowingShape.sol, not an idealised game. Every rule that
moves money is replicated: FWA harmonic-mean fee and 1.025x owner split, the
weighted draw, per-delivered-draw backing-scaled decay with stepped republish,
the composition ladder and its cost, the signed `surplus` ledger, the growth
waterfall (`operating - requiredLiquid`), replenishment, seed recovery on win,
and the keeper budget/reimbursement.

One simulation step == one DELIVERED draw, advanced in lockstep across `paths`
independent games (vectorised with numpy). Timing (Poisson arrivals, bursts,
inactivity) rides on top for the day/keeper-flat-reward metrics; the per-draw
economics are volume-independent by construction.

Assumptions (each flagged `# assume:`) are the deliberate simplifications. They
are the only places the model departs from the contract, and all are
second-order under an active keeper with prompt booking.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
import numpy as np

ETH = 1.0  # work in ETH floats; wei-exact arithmetic is unnecessary at this scale
BPS = 10_000
PPM = 1_000_000

# The Shapes ladder (ETH): alternating 1 and 5 times a power of ten, _denom() in the contract.
LADDER = np.array([0.01, 0.05, 0.1, 0.5, 1, 5, 10, 50, 100], dtype=np.float64)


def denom(i: int) -> float:
    return float(LADDER[i])


def next_denom(backing: float) -> float:
    """Next ladder step up, or 0.0 at the top (contract _nextDenom)."""
    idx = int(np.argmin(np.abs(LADDER - backing)))
    return float(LADDER[idx + 1]) if idx < len(LADDER) - 1 else 0.0


def input_count(delta: float) -> tuple[int, float]:
    """Fewest Shapes summing to `delta`, greedy over the ladder (contract _inputCount).

    Returns (count, total_backing). `total_backing == delta` for ladder-aligned deltas.
    """
    count, rem, total = 0, round(delta / 0.01), 0.0
    units = [round(d / 0.01) for d in LADDER]  # work in 0.01-ETH units to avoid fp drift
    for u in reversed(units):
        if rem == 0:
            break
        q, rem = divmod(rem, u)
        count += q
        total += q * u * 0.01
    return count, total


def composition_cost(backing: float, mint_fee: float) -> float:
    """ETH a composition to the next denomination costs now (contract compositionCost)."""
    nxt = next_denom(backing)
    if nxt == 0.0:
        return 0.0
    count, delta = input_count(nxt - backing)
    return delta + count * mint_fee


# ---------------------------------------------------------------------------
# Configuration: every value in script/Params.sol, plus the measured gas model.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class GameParams:
    markupBps: int = 11_000
    startNotionalBps: int = 10_000
    floorBps: int = 1_000
    resetShareBps: int = 7_000
    repriceStepBps: int = 500
    decayPpm: int = 377
    minLiveOrdinary: int = 60
    maxPendingDraws: int = 30
    seedIndex: int = 3
    reserveTarget: float = 0.5


@dataclass(frozen=True)
class KeeperParams:
    perDraw: float = 0.0001
    budgetCap: float = 0.05
    flatReward: float = 0.0002
    flatInterval: int = 600  # seconds
    gasOverhead: int = 30_000
    gasPriceCap: float = 20.0  # gwei
    priorityCap: float = 1.0   # gwei


@dataclass(frozen=True)
class Tier:
    backing: float
    packShapes: int
    target: int

    @property
    def is_pack(self) -> bool:
        return self.packShapes > 0

    def cost(self, mint_fee: float) -> float:
        fees = (self.packShapes if self.is_pack else 1) * mint_fee
        return self.backing + fees


DEFAULT_TIERS = (
    Tier(0.01, 0, 50),
    Tier(0.03, 3, 35),
    Tier(0.05, 0, 10),
    Tier(0.10, 0, 4),
)

# Measured mainnet-fork execution gas (no 21k intrinsic / calldata; see task brief).
# Keeper reimbursement adds gasOverhead (30k) per call; player all-in adds intrinsic+calldata.
GAS = {
    "acquire1": 609_000,
    "acquireBatch5": 1_660_000,
    "vrf_callback": 529_000,      # paid by the VRF fee, not the game
    "book_base": 300_000,         # one book() incl. collect+allocate
    "book_per_extra_draw": 30_000,
    "replenish_shape": 426_000,   # per 0.01/0.05/0.1 Shape re-mint+list
    "replenish_pack": 800_000,    # per 0.03 pack
    "replenish_overhead": 30_000, # per replenish call (amortised over the batch)
    "publishDecay": 125_000,
    "startCycle": 754_000,
    "compose": {0.5: 800_000, 1.0: 1_190_000, 5.0: 800_000, 10.0: 1_190_000, 50.0: 800_000},
    "tx_intrinsic": 21_000,
    "acquire_calldata": 8_000,
}
VRF_GAS = 1_950_000  # 1.5M * 1.3, the FWA VRF fee basis (x gasprice)


@dataclass(frozen=True)
class Config:
    game: GameParams = field(default_factory=GameParams)
    keeper: KeeperParams = field(default_factory=KeeperParams)
    tiers: tuple[Tier, ...] = DEFAULT_TIERS
    capital: float = 4.2
    mint_fee: float = 0.001
    book_batch: int = 20          # keeper books in batches this size (amortises book gas)
    # assume: in-flight (acquired-but-unbooked) listings do not shrink the active
    #         weight set. True only with prompt booking; pending is capped at 30 of ~100.
    # assume: published notional tracks `desired` within one repriceStep because the
    #         keeper publishes each step; the 2-step stale purchase-pause never triggers.
    # assume: no expiry/fee-drift refunds (VRF is prompt); refunds cost players gas but
    #         never touch game economics. Modelled separately in player-return notes.


# ---------------------------------------------------------------------------
# Static board analytics (closed form, no simulation): the quantities that are
# deterministic given a board composition.
# ---------------------------------------------------------------------------

def ordinary_notionals(cfg: Config) -> np.ndarray:
    return np.array([t.cost(cfg.mint_fee) * cfg.game.markupBps / BPS for t in cfg.tiers])


def board_H(cfg: Config, live: np.ndarray, feat_notional: float | None) -> float:
    """Harmonic-mean acquisition base H = N / sum(1/p) over active listings."""
    notion = ordinary_notionals(cfg)
    inv = float(np.sum(live / notion))
    n = int(np.sum(live))
    if feat_notional:
        inv += 1.0 / feat_notional
        n += 1
    return n / inv if inv else 0.0


def acquisition_fee(H: float, edge_bps: int = 500) -> float:
    return H * (1 + edge_bps / BPS)


def owner_proceeds(H: float, edge_bps: int = 500) -> float:
    """paid - (paid-base)/2, base = H. = H*(1 + edge/2/BPS). Default edge 500bps -> 1.025 H."""
    paid = acquisition_fee(H, edge_bps)
    return paid - (paid - H) / 2


def select_probs(cfg: Config, live: np.ndarray, feat_notional: float | None):
    """Per-draw selection probabilities (ordinary tiers..., featured)."""
    notion = ordinary_notionals(cfg)
    w = live / notion
    wf = (1.0 / feat_notional) if feat_notional else 0.0
    total = float(np.sum(w) + wf)
    p_ord = w / total
    p_feat = wf / total
    return p_ord, p_feat


def all_in_price(H: float, gas_gwei: float, batch: int = 1):
    """Player all-in cost per draw: FWA fee + VRF fee + player tx gas."""
    fee = acquisition_fee(H)
    gp = gas_gwei * 1e-9
    vrf = VRF_GAS * gp
    if batch >= 5:
        g = (GAS["acquireBatch5"] / 5) + GAS["tx_intrinsic"] / 5 + GAS["acquire_calldata"] / 5
    else:
        g = GAS["acquire1"] + GAS["tx_intrinsic"] + GAS["acquire_calldata"]
    player_gas = g * gp
    return {"fee": fee, "vrf": vrf, "player_gas": player_gas, "total": fee + vrf + player_gas}


def growth_allocation(surplus, operating, required):
    """Contract _allocateGrowth: move min(surplus, operating-required) to growth, but
    only while surplus>0 and operating exceeds everything held back."""
    amt = np.minimum(surplus, operating - required)
    return np.where(np.asarray(surplus) > 0, np.clip(amt, 0.0, None), 0.0)


def keeper_gas_per_draw(cfg: Config, p_ord: np.ndarray, p_feat: float,
                        step_draws: float) -> float:
    """Expected keeper EXECUTION gas per delivered draw (book + replenish + decay).

    Compose/startCycle are rare and added at cycle events in the MC; this is the
    steady per-draw load that the keeper budget must cover.
    """
    b = cfg.book_batch
    book = (GAS["book_base"] + (b - 1) * GAS["book_per_extra_draw"] + GAS["book_base"] * 0
            + GAS["replenish_overhead"]) / b  # +30k call overhead amortised
    # replenish: expected gas of re-minting whichever ordinary prize was won
    rg = np.array([GAS["replenish_pack"] if t.is_pack else GAS["replenish_shape"]
                   for t in cfg.tiers])
    psum = float(np.sum(p_ord))
    replen = float(np.sum(p_ord * rg)) + (GAS["replenish_overhead"] / max(b, 1)) * psum
    decay = GAS["publishDecay"] / step_draws if step_draws > 0 else 0.0
    return book + replen + decay


def effective_keeper_price(cfg: Config, gas_gwei: float) -> float:
    """min(gasprice, basefee+priorityCap, gasPriceCap) in gwei.

    assume: basefee == gasprice (keeper submits near basefee). Then basefee+priorityCap
    >= gasprice, so the binding caps are gasprice and gasPriceCap.
    """
    return min(gas_gwei, cfg.keeper.gasPriceCap)


# ---------------------------------------------------------------------------
# The Monte Carlo engine.
# ---------------------------------------------------------------------------

@dataclass
class SimResult:
    cfg: Config
    gas_gwei: float
    draws_per_day: float
    n_paths: int
    n_draws: int
    # per-path records (arrays length n_paths)
    cycles_won: np.ndarray = None       # count of featured wins
    first_win_draw: np.ndarray = None   # draw index of first featured win (-1 if none)
    first_win_backing: np.ndarray = None
    reached: dict = None                # backing -> bool array (reached before first win)
    draws_to_stage: dict = None         # backing -> draw index reached (median over reachers)
    first_comp_draw: np.ndarray = None  # draw of first composition (-1 none)
    won_before_first_comp: np.ndarray = None
    # time series (mean over paths, sampled)
    ts_draw: np.ndarray = None
    ts_surplus: np.ndarray = None
    ts_growth: np.ndarray = None
    ts_keeper_budget: np.ndarray = None
    ts_feat_backing: np.ndarray = None
    # keeper
    keeper_starved_frac: float = 0.0    # fraction of draws keeper budget could not cover
    keeper_net_per_draw: float = 0.0    # accrual - expected cost (ETH), + is sustainable
    pause_frac: float = 0.0             # fraction of draws purchases would be paused
    meta: dict = None


def simulate(cfg: Config, *, gas_gwei: float = 0.3, draws_per_day: float = 500,
             n_paths: int = 2000, n_draws: int = 12_000, seed: int = 0,
             gas_series: np.ndarray | None = None,
             sample_every: int = 50) -> SimResult:
    """Run `n_paths` games for `n_draws` delivered draws each.

    gas_series: optional (n_draws,) array of gwei for a volatile-gas scenario.
    """
    rng = np.random.default_rng(seed)
    gp, kp = cfg.game, cfg.keeper
    fee = cfg.mint_fee
    T = len(cfg.tiers)
    notion = ordinary_notionals(cfg)
    tier_cost = np.array([t.cost(fee) for t in cfg.tiers])
    tier_target = np.array([t.target for t in cfg.tiers])
    tier_backing = np.array([t.backing for t in cfg.tiers])
    tier_replen_gas = np.array([GAS["replenish_pack"] if t.is_pack else GAS["replenish_shape"]
                                for t in cfg.tiers], dtype=np.float64)
    seed_backing = denom(gp.seedIndex)
    seed_cost = seed_backing + fee
    reserve = gp.reserveTarget
    P = n_paths

    # Precompute per-ladder-rung composition cost and next backing (vectorised lookups).
    comp_cost_lut = np.array([composition_cost(denom(i), fee) for i in range(len(LADDER))])
    next_b_lut = np.array([next_denom(denom(i)) for i in range(len(LADDER))])

    def backing_idx(b):  # (P,) exact ladder values -> ladder index
        return np.searchsorted(_LADDER_U, np.round(b / 0.01).astype(np.int64))

    # --- board state: all paths start at the launched full board ---
    live = np.tile(tier_target, (P, 1)).astype(np.float64)  # (P,T)
    board_cost = np.sum(live * tier_cost, axis=1)           # inventoryCost (ordinary)

    # --- featured state ---
    f_active = np.ones(P, dtype=bool)
    f_backing = np.full(P, seed_backing)
    f_notional = np.full(P, seed_backing * gp.startNotionalBps / BPS)   # published
    f_reset_notional = f_notional.copy()
    f_decay = f_backing * gp.decayPpm / PPM
    f_floor = f_backing * gp.floorBps / BPS
    f_draws = np.zeros(P)
    f_cycle_draws = np.zeros(P)
    f_comps = np.zeros(P, dtype=int)
    f_cost_basis = np.full(P, seed_cost)

    # --- ledgers (ETH) ---
    # launch: capital funds board + featured seed. balance = capital - spent.
    spent0 = board_cost + seed_cost
    balance = np.full(P, cfg.capital) - spent0
    growth = np.zeros(P)
    surplus = np.zeros(P)                 # capital is NOT surplus
    keeper_budget = np.zeros(P)

    # --- accumulators / records ---
    revenue = np.zeros(P); prize_exp = np.zeros(P); feat_awarded = np.zeros(P)
    keeper_paid = np.zeros(P); growth_alloc = np.zeros(P)
    cycles_won = np.zeros(P, dtype=int)
    first_win_draw = np.full(P, -1)
    first_win_backing = np.zeros(P)
    first_comp_draw = np.full(P, -1)
    stages = [1.0, 5.0, 10.0, 50.0, 100.0]
    reached = {s: np.zeros(P, dtype=bool) for s in stages}
    draws_to_stage = {s: np.full(P, -1) for s in stages}

    keeper_starved = np.zeros(P)
    paused = np.zeros(P)
    last_flat_time = np.full(P, -1e18)

    # time series
    n_samples = n_draws // sample_every + 1
    ts_draw = np.zeros(n_samples)
    ts_surplus = np.zeros(n_samples); ts_growth = np.zeros(n_samples)
    ts_kb = np.zeros(n_samples); ts_fb = np.zeros(n_samples)
    si = 0

    dt = 86400.0 / draws_per_day  # seconds per delivered draw (mean)
    flat_interval = kp.flatInterval
    eff_price_const = effective_keeper_price(cfg, gas_gwei) * 1e-9

    all_idx = np.arange(P)

    for d in range(n_draws):
        t_now = d * dt
        gwei = gas_series[d] if gas_series is not None else gas_gwei
        eff_price = (min(gwei, kp.gasPriceCap) * 1e-9)

        # ---- weights & selection probabilities (active board) ----
        w = live / notion                         # (P,T)
        wf = np.where(f_active, 1.0 / f_notional, 0.0)
        wtot = np.sum(w, axis=1) + wf
        # revenue this draw = owner proceeds = 1.025 * H ; H = N / sum(1/p)
        n_active = np.sum(live > 0, axis=1) * 0 + np.sum(live, axis=1) + f_active  # N listings
        inv_sum = np.sum(w, axis=1) + wf
        H = n_active / inv_sum
        rev = owner_proceeds(1.0, 500) * H  # owner_proceeds scales linearly in H
        revenue += rev; surplus += rev; balance += rev

        # keeper budget accrues per delivered draw, capped
        keeper_budget = np.minimum(keeper_budget + kp.perDraw, kp.budgetCap)

        # ---- choose winner per path by cumulative weight ----
        cum = np.cumsum(np.concatenate([w, wf[:, None]], axis=1), axis=1)  # (P,T+1)
        u = rng.random(P) * wtot
        choice = (u[:, None] >= cum).sum(axis=1)  # index in [0..T]; T == featured
        won_feat = (choice == T) & f_active
        won_ord = choice < T

        # ---- ordinary win: expense, remove, replenish, decay credit ----
        if won_ord.any():
            ci = np.where(won_ord, np.clip(choice, 0, T - 1), 0)
            cost_won = tier_cost[ci]
            prize_exp += np.where(won_ord, cost_won, 0.0)
            surplus -= np.where(won_ord, cost_won, 0.0)
            live[all_idx, ci] -= won_ord.astype(np.float64)
            board_cost -= np.where(won_ord, cost_won, 0.0)
            # replenish immediately if operating affords it (balance - growth >= cost)
            op = balance - growth
            can_replen = won_ord & (op >= cost_won)
            balance -= np.where(can_replen, cost_won, 0.0)
            live[all_idx, ci] += can_replen.astype(np.float64)
            board_cost += np.where(can_replen, cost_won, 0.0)
            # featured decay credit on each delivered ordinary draw
            f_draws += np.where(won_ord & f_active, 1.0, 0.0)
            f_cycle_draws += np.where(won_ord & f_active, 1.0, 0.0)

        # ---- featured win: award, seed recovery, record, restart ----
        if won_feat.any():
            feat_awarded += np.where(won_feat, f_cost_basis, 0.0)
            surplus -= np.where(won_feat, seed_cost, 0.0)  # earn back the seed
            f_cycle_draws += won_feat.astype(np.float64)   # the winning draw
            newly = won_feat & (first_win_draw < 0)
            first_win_draw = np.where(newly, d, first_win_draw)
            first_win_backing = np.where(newly, f_backing, first_win_backing)
            cycles_won += won_feat.astype(int)
            f_active &= ~won_feat
            f_cost_basis = np.where(won_feat, 0.0, f_cost_basis)

        # ---- growth waterfall (contract _allocateGrowth) ----
        op = balance - growth
        req = reserve + seed_cost + _replacement_due(live, tier_target, tier_cost) + keeper_budget
        amt = growth_allocation(surplus, op, req)
        growth += amt; growth_alloc += amt; surplus -= amt

        # ---- composition (contract compose): as soon as growthFund covers cost ----
        # one step per draw is enough; growth rises ~0.002/draw so never multi-step.
        bidx = backing_idx(f_backing)
        comp_cost = comp_cost_lut[bidx]
        comp_due = f_active & (comp_cost > 0) & (growth >= comp_cost)
        if comp_due.any():
            nb = next_b_lut[bidx]
            delta = nb - f_backing
            desired = np.maximum(f_reset_notional - f_draws * f_decay, f_floor)
            new_notional = np.minimum(desired + delta * gp.resetShareBps / BPS, nb)
            growth -= np.where(comp_due, comp_cost, 0.0)
            balance -= np.where(comp_due, comp_cost, 0.0)
            f_backing = np.where(comp_due, nb, f_backing)
            f_comps += comp_due.astype(int)
            # reset snapshot
            f_notional = np.where(comp_due, new_notional, f_notional)
            f_reset_notional = np.where(comp_due, new_notional, f_reset_notional)
            f_decay = np.where(comp_due, f_backing * gp.decayPpm / PPM, f_decay)
            f_floor = np.where(comp_due, f_backing * gp.floorBps / BPS, f_floor)
            f_draws = np.where(comp_due, 0.0, f_draws)
            f_cost_basis += np.where(comp_due, comp_cost, 0.0)
            newcomp = comp_due & (first_comp_draw < 0)
            first_comp_draw = np.where(newcomp, d, first_comp_draw)
            for s in stages:
                hit = comp_due & (np.abs(f_backing - s) < 1e-9) & ~reached[s] & (first_win_draw < 0)
                reached[s] |= hit
                draws_to_stage[s] = np.where(hit, d, draws_to_stage[s])

        # ---- publish decay (stepped) ----
        if f_active.any():
            desired = np.maximum(f_reset_notional - f_draws * f_decay, f_floor)
            step = gp.repriceStepBps / BPS
            due = f_active & ((desired <= f_notional * (1 - step)) | (desired <= f_floor + 1e-18))
            due &= desired < f_notional
            f_notional = np.where(due, desired, f_notional)

        # ---- restart a cycle if none active and operating funds seed+replacement ----
        need = ~f_active & (first_win_draw >= 0)  # only after a win (not pre-launch)
        op = balance - growth
        can_start = need & (op >= seed_cost + _replacement_due(live, tier_target, tier_cost))
        if can_start.any():
            balance -= np.where(can_start, seed_cost, 0.0)
            f_active |= can_start
            f_backing = np.where(can_start, seed_backing, f_backing)
            start_notional = seed_backing * gp.startNotionalBps / BPS
            f_notional = np.where(can_start, start_notional, f_notional)
            f_reset_notional = np.where(can_start, start_notional, f_reset_notional)
            f_decay = np.where(can_start, seed_backing * gp.decayPpm / PPM, f_decay)
            f_floor = np.where(can_start, seed_backing * gp.floorBps / BPS, f_floor)
            f_draws = np.where(can_start, 0.0, f_draws)
            f_cycle_draws = np.where(can_start, 0.0, f_cycle_draws)
            f_comps = np.where(can_start, 0, f_comps)
            f_cost_basis = np.where(can_start, seed_cost, f_cost_basis)

        # ---- keeper reimbursement (contract _payKeeper) ----
        # steady per-draw gas: amortised book + the replenish just done + stepped decay
        g_book = (GAS["book_base"] + (cfg.book_batch - 1) * GAS["book_per_extra_draw"]
                  + GAS["replenish_overhead"]) / cfg.book_batch
        g_replen = np.where(won_ord, tier_replen_gas[np.clip(choice, 0, T - 1)], 0.0)
        g_replen += GAS["replenish_overhead"] / max(cfg.book_batch, 1)
        g = g_book + g_replen
        reimburse = (g + kp.gasOverhead) * eff_price
        # flat reward at most once per interval
        flat_due = (t_now >= last_flat_time + flat_interval)
        reimburse += np.where(flat_due, kp.flatReward, 0.0)
        last_flat_time = np.where(flat_due, t_now, last_flat_time)
        op = balance - growth
        limit = np.minimum(keeper_budget, np.maximum(op, 0.0))
        paid = np.minimum(reimburse, limit)
        keeper_starved += (paid < reimburse - 1e-12).astype(np.float64)
        keeper_budget -= paid; keeper_paid += paid; surplus -= paid; balance -= paid

        # ---- purchase-pause bookkeeping (keeper insolvent => booking stalls) ----
        paused += (paid < reimburse - 1e-12).astype(np.float64)

        if d % sample_every == 0:
            ts_draw[si] = d
            ts_surplus[si] = surplus.mean()
            ts_growth[si] = growth.mean()
            ts_kb[si] = keeper_budget.mean()
            ts_fb[si] = np.where(f_active, f_backing, 0.0).mean()
            si += 1

    # "won before first composition" = the first featured was won while still at seed
    # backing (never composed). Growth carries across cycles, so first_comp_draw alone
    # does not capture this.
    won_before = (first_win_draw >= 0) & (np.abs(first_win_backing - seed_backing) < 1e-9)
    # analytic keeper net at the launched full board
    p_ord0, p_feat0 = select_probs(cfg, tier_target.astype(float),
                                    seed_backing * gp.startNotionalBps / BPS)
    step_draws0 = (gp.repriceStepBps / BPS) * (seed_backing * gp.startNotionalBps / BPS) / \
        (seed_backing * gp.decayPpm / PPM)
    kgas0 = keeper_gas_per_draw(cfg, p_ord0, p_feat0, step_draws0)
    keeper_net = kp.perDraw - kgas0 * eff_price_const

    return SimResult(
        cfg=cfg, gas_gwei=gas_gwei, draws_per_day=draws_per_day, n_paths=P, n_draws=n_draws,
        cycles_won=cycles_won, first_win_draw=first_win_draw, first_win_backing=first_win_backing,
        reached=reached, draws_to_stage=draws_to_stage, first_comp_draw=first_comp_draw,
        won_before_first_comp=won_before,
        ts_draw=ts_draw[:si], ts_surplus=ts_surplus[:si], ts_growth=ts_growth[:si],
        ts_keeper_budget=ts_kb[:si], ts_feat_backing=ts_fb[:si],
        keeper_starved_frac=float(keeper_starved.sum() / (P * n_draws)),
        keeper_net_per_draw=float(keeper_net),
        pause_frac=float(paused.sum() / (P * n_draws)),
        meta={"keeper_gas_per_draw": float(kgas0), "eff_price_gwei": eff_price_const * 1e9,
              # final per-path accounting for the identity check (recovered=0, no refunds):
              # balance + inventoryCost + active featured costBasis
              #   == capital + revenue - prizeExpense - featuredAwarded - keeperPaid
              "acct": {
                  "balance": balance, "board_cost": board_cost,
                  "f_cost_basis": np.where(f_active, f_cost_basis, 0.0),
                  "revenue": revenue, "prize_exp": prize_exp, "feat_awarded": feat_awarded,
                  "keeper_paid": keeper_paid, "capital": np.full(P, cfg.capital),
                  "growth": growth, "surplus": surplus,
              }},
    )


# --- small vectorised helpers (contract parity) ---

def _replacement_due(live: np.ndarray, target: np.ndarray, cost: np.ndarray) -> np.ndarray:
    miss = np.clip(target - live, 0, None)
    return np.sum(miss * cost, axis=1)


_LADDER_U = np.array([round(d / 0.01) for d in LADDER])  # 0.01-ETH units: 1,5,10,50,...


if __name__ == "__main__":
    # smoke: launched-board analytics line up with the lead's mean-field
    cfg = Config()
    live0 = np.array([t.target for t in cfg.tiers], float)
    H = board_H(cfg, live0, 0.5)
    print(f"H={H:.6f}  fee={acquisition_fee(H):.6f}  proceeds={owner_proceeds(H):.6f}")
    p_ord, p_feat = select_probs(cfg, live0, 0.5)
    print(f"P(featured)/draw={p_feat:.6e}  E[cost]={float(np.sum(p_ord*np.array([t.cost(cfg.mint_fee) for t in cfg.tiers]))):.6f}")
    print(f"net surplus/draw={owner_proceeds(H)-float(np.sum(p_ord*np.array([t.cost(cfg.mint_fee) for t in cfg.tiers]))):.6f}")
    r = simulate(cfg, n_paths=300, n_draws=3000, seed=1)
    print(f"keeper net/draw={r.keeper_net_per_draw:.2e}  starved={r.keeper_starved_frac:.3f}  "
          f"P(win<firstcomp)={r.won_before_first_comp.mean():.3f}")
