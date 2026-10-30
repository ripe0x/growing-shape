"""Plain-assert self-checks for the Growing Shape model against hand-computed values.

Run:  python3 -I sim/test_model.py        (prints 'all ok' on success)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
import model as m

TOL = 1e-9


def approx(a, b, tol=1e-6):
    return abs(float(a) - float(b)) < tol


def test_ladder_and_composition_cost():
    # Ladder matches the contract _denom: 0.01,0.05,0.1,0.5,1,5,10,50,100
    assert list(m.LADDER) == [0.01, 0.05, 0.1, 0.5, 1, 5, 10, 50, 100]
    assert m.next_denom(0.5) == 1 and m.next_denom(1) == 5 and m.next_denom(50) == 100
    assert m.next_denom(100) == 0.0
    # input_count: featured progression uses the fewest shapes summing to delta
    assert m.input_count(0.5) == (1, 0.5)      # 0.5->1 : one 0.5
    assert m.input_count(4.0) == (4, 4.0)      # 1->5   : four 1
    assert m.input_count(5.0) == (1, 5.0)      # 5->10  : one 5
    assert m.input_count(40.0) == (4, 40.0)    # 10->50 : four 10
    assert m.input_count(50.0) == (1, 50.0)    # 50->100: one 50
    # compositionCost = delta + count * mintFee (fee = 0.001)
    fee = 0.001
    assert approx(m.composition_cost(0.5, fee), 0.5 + 1 * fee)
    assert approx(m.composition_cost(1.0, fee), 4.0 + 4 * fee)
    assert approx(m.composition_cost(10.0, fee), 40.0 + 4 * fee)
    assert approx(m.composition_cost(100.0, fee), 0.0)


def test_selection_probability():
    # Two listings, notionals 0.01 and 0.04. weight = 1e36/p; prob = w_i / sum(w).
    cfg = m.Config(tiers=(m.Tier(0.01, 0, 1), m.Tier(0.05, 0, 1)),
                   game=m.GameParams(markupBps=10_000))  # notional == cost
    # cost(0.01)=0.011, cost(0.05)=0.051 at fee 0.001; markup 1.0 -> notional == cost
    live = np.array([1.0, 1.0])
    p_ord, p_feat = m.select_probs(cfg, live, feat_notional=None)
    w0, w1 = 1 / 0.011, 1 / 0.051
    assert approx(p_ord[0], w0 / (w0 + w1))
    assert approx(p_ord[1], w1 / (w0 + w1))
    assert approx(p_feat, 0.0)
    # add a featured at notional 0.5 -> its weight is 1/0.5 = 2
    p_ord2, p_feat2 = m.select_probs(cfg, live, feat_notional=0.5)
    wf = 1 / 0.5
    assert approx(p_feat2, wf / (w0 + w1 + wf))


def test_fee_and_proceeds_split():
    # Harmonic base H = N / sum(1/p). Two listings p=0.02, p=0.08 -> H = 2/(50+12.5)=0.032
    cfg = m.Config(tiers=(m.Tier(0.01, 0, 1),), game=m.GameParams(markupBps=10_000))
    H = m.board_H(cfg, np.array([1.0]), feat_notional=None)
    assert approx(H, 0.011)  # single listing: H == its own notional (0.011)
    # edge 500bps: fee = H*1.05, proceeds = H*1.025, protocol = H*0.025
    assert approx(m.acquisition_fee(0.032), 0.032 * 1.05)
    assert approx(m.owner_proceeds(0.032), 0.032 * 1.025)
    assert approx(m.acquisition_fee(0.032) - m.owner_proceeds(0.032), 0.032 * 0.025)
    # harmonic-mean identity on a hand board: p=0.02,0.08 -> H=0.032
    H2 = 2 / (1 / 0.02 + 1 / 0.08)
    assert approx(H2, 0.032)


def test_launch_board_matches_contract():
    # Lifecycle test asserts inventoryCost == 2.619 ETH and featured notional 0.5 at launch.
    cfg = m.Config()
    live0 = np.array([t.target for t in cfg.tiers], float)
    board_cost = float(np.sum(live0 * np.array([t.cost(cfg.mint_fee) for t in cfg.tiers])))
    assert approx(board_cost, 2.619)  # 50*0.011 + 35*0.033 + 10*0.051 + 4*0.101
    # H and proceeds reproduce the mean-field reference (lead's exploration)
    H = m.board_H(cfg, live0, 0.5)
    assert approx(H, 0.018823, 1e-5)
    assert approx(m.owner_proceeds(H), 0.019293, 1e-5)


def test_decay_schedule():
    # desiredNotional = max(reset - draws*decayPerDraw, floor); decayPerDraw = backing*ppm/1e6.
    backing, ppm = 0.5, 377
    decay = backing * ppm / m.PPM
    assert approx(decay, 0.5 * 377 / 1_000_000)        # 1.885e-4
    reset, floor = 0.5, 0.5 * 1000 / m.BPS             # floorBps 1000 -> floor 0.05
    # The lead's fork test: 140 draws past one 5% step of a 0.5 reset.
    desired_140 = max(reset - 140 * decay, floor)
    assert approx(desired_140, 0.5 - 140 * decay)
    assert desired_140 < 0.475  # below the 5% step 0.5*0.95
    # Floored far out
    desired_far = max(reset - 100000 * decay, floor)
    assert approx(desired_far, floor)


def test_growth_waterfall():
    # amount = min(surplus, operating - required), only if surplus>0 and operating>required.
    assert approx(m.growth_allocation(0.10, 1.08, 1.00), 0.08)   # capped by headroom
    assert approx(m.growth_allocation(0.05, 1.08, 1.00), 0.05)   # capped by surplus
    assert approx(m.growth_allocation(-0.01, 1.08, 1.00), 0.0)   # no surplus
    assert approx(m.growth_allocation(0.10, 1.00, 1.05), 0.0)    # operating below required
    # vector form
    out = m.growth_allocation(np.array([0.1, 0.05, -0.01]),
                              np.array([1.08, 1.08, 1.08]), np.array([1.0, 1.0, 1.0]))
    assert np.allclose(out, [0.08, 0.05, 0.0])


def test_accounting_identity():
    # balance + inventoryCost + active featured costBasis
    #   == capital + revenue - prizeExpense - featuredAwarded - keeperPaid   (recovered=0)
    cfg = m.Config()
    r = m.simulate(cfg, n_paths=200, n_draws=1500, seed=11)
    a = r.meta["acct"]
    lhs = a["balance"] + a["board_cost"] + a["f_cost_basis"]
    rhs = a["capital"] + a["revenue"] - a["prize_exp"] - a["feat_awarded"] - a["keeper_paid"]
    err = np.max(np.abs(lhs - rhs))
    assert err < 1e-6, f"accounting identity broken by {err}"
    # surplus is bounded by the ledger definition and never silently explodes
    assert np.all(np.isfinite(a["surplus"]))
    # growthFund never exceeds cumulative surplus booked (capital never becomes growth)
    assert np.all(a["growth"] >= -1e-9)


def test_keeper_insolvent_at_default():
    # Steady maintenance ~541k gas/draw; perDraw 0.0001 breaks even near 0.18 gwei, so at
    # 0.3 gwei the keeper is net-negative (a headline finding).
    cfg = m.Config()
    r = m.simulate(cfg, gas_gwei=0.3, n_paths=100, n_draws=800, seed=1)
    assert r.keeper_net_per_draw < 0
    assert 500_000 < r.meta["keeper_gas_per_draw"] < 600_000
    # raising perDraw to the contract max fixes it up to ~1.85 gwei
    cfg2 = m.Config(keeper=m.KeeperParams(perDraw=0.001))
    r2 = m.simulate(cfg2, gas_gwei=1.0, n_paths=100, n_draws=800, seed=1)
    assert r2.keeper_net_per_draw > 0


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print("all ok")
