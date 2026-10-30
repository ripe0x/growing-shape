"""Named, reproducible sweeps for the Growing Shape economic model.

Usage:
    python3 -I sim/run.py all            # every sweep (a few minutes)
    python3 -I sim/run.py static price keeper lifecycle params board volume longrun
    python3 -I sim/run.py lifecycle --paths 5000 --draws 10000 --seed 7

Outputs land in sim/results/ as markdown (for docs) + JSON (raw). Seeds are
fixed so every table reproduces.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # make -I imports work

import numpy as np
import model as m

RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
GAS_LEVELS = [0.3, 1, 3, 10, 30]
VOLUMES = [20, 100, 500, 2000]


# --------------------------- output helpers ---------------------------

def _w(name: str, md: str, data):
    os.makedirs(RESULTS, exist_ok=True)
    with open(os.path.join(RESULTS, name + ".md"), "w") as f:
        f.write(md)
    with open(os.path.join(RESULTS, name + ".json"), "w") as f:
        json.dump(data, f, indent=2, default=float)
    print(f"wrote results/{name}.md and .json")


def table(headers, rows) -> str:
    out = "| " + " | ".join(headers) + " |\n"
    out += "| " + " | ".join("---" for _ in headers) + " |\n"
    for r in rows:
        out += "| " + " | ".join(str(c) for c in r) + " |\n"
    return out


def pct(x):
    return f"{100*x:.1f}%"


# --------------------------- sweeps ---------------------------

def sweep_static(args):
    """Closed-form board economics: deterministic given a board (no MC)."""
    cfg = m.Config()
    live0 = np.array([t.target for t in cfg.tiers], float)
    seed_notional = m.denom(cfg.game.seedIndex) * cfg.game.startNotionalBps / m.BPS
    H = m.board_H(cfg, live0, seed_notional)
    p_ord, p_feat = m.select_probs(cfg, live0, seed_notional)
    e_cost = float(np.sum(p_ord * np.array([t.cost(cfg.mint_fee) for t in cfg.tiers])))
    proceeds = m.owner_proceeds(H)
    net = proceeds - e_cost

    # P(featured)/draw at each stage: backing, notional at start-of-stage and at floor
    stages = [(0.5, cfg.game.startNotionalBps), (1, None), (5, None), (10, None), (50, None), (100, None)]
    stage_rows = []
    for b, _ in stages:
        start_n = min(b, (seed_notional if b == 0.5 else b))  # notional right after reset ~ backing-capped
        floor_n = b * cfg.game.floorBps / m.BPS
        p_start = m.select_probs(cfg, live0, start_n)[1]
        p_floor = m.select_probs(cfg, live0, floor_n)[1]
        stage_rows.append([f"{b}", f"{floor_n:g}", f"{p_start:.2e}", f"{p_floor:.2e}",
                           f"{1/p_start:,.0f}", f"{1/p_floor:,.0f}"])

    md = "# Static board economics (recommended config)\n\n"
    md += f"Board: {[ (t.backing,t.target) for t in cfg.tiers]}, markup {cfg.game.markupBps/100:.0f}%, "
    md += f"featured seed {m.denom(cfg.game.seedIndex)} ETH.\n\n"
    md += table(["metric", "value (ETH)"], [
        ["harmonic base H", f"{H:.6f}"],
        ["acquisition fee (1.05 H)", f"{m.acquisition_fee(H):.6f}"],
        ["owner proceeds / delivered draw (1.025 H)", f"{proceeds:.6f}"],
        ["E[prize cost] / draw", f"{e_cost:.6f}"],
        ["net surplus / draw (pre-keeper)", f"{net:.6f}"],
        ["P(featured won)/draw at seed notional", f"{p_feat:.2e}"],
    ])
    md += "\n## P(win featured) per draw by stage\n\n"
    md += table(["backing", "floor notional", "P/draw @reset", "P/draw @floor", "1/P @reset", "1/P @floor"], stage_rows)
    md += "\n## Expected draws to fund each composition (growth at net surplus/draw)\n\n"
    cum, rows = 0.0, []
    for b in [0.5, 1, 5, 10, 50]:
        c = m.composition_cost(b, cfg.mint_fee)
        cum += c
        rows.append([f"{b}->{m.next_denom(b):g}", f"{c:.3f}", f"{cum:.3f}", f"{c/net:,.0f}", f"{cum/net:,.0f}"])
    md += table(["step", "cost ETH", "cumulative ETH", "draws (step)", "draws (cumulative from seed)"], rows)
    _w("static", md, {"H": H, "fee": m.acquisition_fee(H), "proceeds": proceeds,
                      "e_cost": e_cost, "net_surplus_per_draw": net, "p_feat_seed": p_feat})


def sweep_price(args):
    """All-in player draw price across gas, for a few markups."""
    rows = []
    for markup in [10_500, 10_750, 11_000, 11_500, 12_000]:
        cfg = m.Config(game=m.GameParams(markupBps=markup))
        live0 = np.array([t.target for t in cfg.tiers], float)
        seed_n = m.denom(cfg.game.seedIndex) * cfg.game.startNotionalBps / m.BPS
        H = m.board_H(cfg, live0, seed_n)
        row = [f"{markup/100:.1f}%", f"{m.acquisition_fee(H):.5f}"]
        for g in GAS_LEVELS:
            p1 = m.all_in_price(H, g, batch=1)["total"]
            p5 = m.all_in_price(H, g, batch=5)["total"]
            row.append(f"{p1:.5f}/{p5:.5f}")
        rows.append(row)
    md = "# All-in player draw price (ETH): single acquire / batch-of-5, by gas\n\n"
    md += "fee is gas-independent; VRF (1.95M*gas) and player tx gas add the rest. Target <= 0.020 at low gas.\n\n"
    md += table(["markup", "fee"] + [f"{g} gwei" for g in GAS_LEVELS], rows)
    # component breakdown at recommended markup
    cfg = m.Config()
    H = m.board_H(cfg, np.array([t.target for t in cfg.tiers], float),
                  m.denom(cfg.game.seedIndex) * cfg.game.startNotionalBps / m.BPS)
    md += "\n## Component breakdown at markup 110% (single acquire)\n\n"
    brk = []
    for g in GAS_LEVELS:
        c = m.all_in_price(H, g, 1)
        brk.append([f"{g}", f"{c['fee']:.5f}", f"{c['vrf']:.5f}", f"{c['player_gas']:.5f}", f"{c['total']:.5f}"])
    md += table(["gwei", "fee", "VRF", "player gas", "all-in"], brk)
    _w("price", md, {"note": "fee gas-independent"})


def sweep_keeper(args):
    """Keeper sustainability: net ETH/draw and break-even gas vs perDraw candidates."""
    cfg = m.Config()
    live0 = np.array([t.target for t in cfg.tiers], float)
    p_ord, p_feat = m.select_probs(cfg, live0, m.denom(cfg.game.seedIndex))
    step_draws = (cfg.game.repriceStepBps/m.BPS) * (m.denom(cfg.game.seedIndex)) / \
        (m.denom(cfg.game.seedIndex) * cfg.game.decayPpm / m.PPM)
    kgas = m.keeper_gas_per_draw(cfg, p_ord, p_feat, step_draws)  # exec gas/draw

    rows = []
    for perDraw in [0.0001, 0.0003, 0.0005, 0.001]:
        row = [f"{perDraw:.4f}", f"{perDraw/ (kgas) /1e-9:.2f}"]  # break-even gwei (gas only)
        for g in GAS_LEVELS:
            eff = min(g, cfg.keeper.gasPriceCap)
            cost = kgas * eff * 1e-9
            net = perDraw - cost
            row.append(f"{net:+.2e}")
        rows.append(row)
    md = "# Keeper sustainability\n\n"
    md += f"Steady maintenance load ~= {kgas/1e3:.0f}k execution gas / delivered draw "
    md += "(dominated by replenishing the won prize; ~78% of wins are 0.01 Shapes at 426k gas each).\n\n"
    md += "Contract caps perDraw at 0.001 ETH and the reimbursed price at min(gasprice, 20 gwei). "
    md += "Net ETH/draw = perDraw - gas_per_draw * eff_price. Negative => keeper loses money and stops.\n\n"
    md += table(["perDraw", "break-even gwei"] + [f"net @{g}gwei" for g in GAS_LEVELS], rows)
    md += f"\nBreak-even gas at the MAX allowed perDraw (0.001): **{0.001/kgas/1e-9:.2f} gwei**. "
    md += "Above this, no allowed perDraw keeps the keeper solvent even though realized surplus "
    md += "(~0.0024 ETH/draw) could pay many times the gas.\n"
    # flat-reward burden by volume
    md += "\n## Flat-reward burden by volume (0.0002 ETH at most per 600s)\n\n"
    frows = []
    for v in VOLUMES:
        dt = 86400.0 / v
        per_draw_flat = cfg.keeper.flatReward / max(1.0, 600.0/dt)  # amortised
        per_draw_flat = cfg.keeper.flatReward if dt >= 600 else cfg.keeper.flatReward * dt/600.0
        frows.append([f"{v}", f"{dt:.0f}", f"{per_draw_flat:.6f}", pct(per_draw_flat/0.0001)])
    md += table(["draws/day", "sec/draw", "flat reward/draw", "vs 0.0001 accrual"], frows)
    _w("keeper", md, {"keeper_gas_per_draw": kgas, "breakeven_gwei_at_max_perDraw": 0.001/kgas/1e-9})


def _lifecycle_metrics(r: m.SimResult) -> dict:
    w = r.first_win_draw >= 0
    fb = r.first_win_backing[w]
    dist = {float(k): round(v/len(fb), 4) for k, v in
            sorted(collections.Counter(np.round(fb, 2)).items())} if len(fb) else {}
    out = {
        "frac_won_within_horizon": float(w.mean()),
        "median_first_win_draw": float(np.median(r.first_win_draw[w])) if w.any() else None,
        "won_before_first_comp": float(r.won_before_first_comp.mean()),
        "E_backing_winning_featured": float(fb.mean()) if len(fb) else None,
        "win_backing_distribution": dist,
        "cycles_won_mean": float(r.cycles_won.mean()),
        "keeper_net_per_draw": r.keeper_net_per_draw,
        "keeper_starved_frac": r.keeper_starved_frac,
    }
    for s in [1.0, 5.0, 10.0, 50.0, 100.0]:
        dts = r.draws_to_stage[s][r.draws_to_stage[s] >= 0]
        out[f"P_reach_{s}_before_won"] = float(r.reached[s].mean())
        out[f"median_draws_to_{s}"] = float(np.median(dts)) if len(dts) else None
    return out


def sweep_lifecycle(args):
    cfg = m.Config()
    r = m.simulate(cfg, gas_gwei=0.3, draws_per_day=500,
                   n_paths=args.paths or 4000, n_draws=args.draws or 9000, seed=args.seed)
    m_ = _lifecycle_metrics(r)
    md = "# Lifecycle Monte Carlo (recommended config, 0.3 gwei, 500 draws/day)\n\n"
    md += f"{r.n_paths} paths x {r.n_draws} delivered draws, seed {args.seed}.\n\n"
    md += table(["metric", "value"], [
        ["P(featured won before first composition, at 0.5 ETH)", pct(m_["won_before_first_comp"])],
        ["P(first featured reaches 1 ETH before won)", pct(m_["P_reach_1.0_before_won"])],
        ["P(reaches 5 ETH before won)", pct(m_["P_reach_5.0_before_won"])],
        ["P(reaches 10 ETH before won)", pct(m_["P_reach_10.0_before_won"])],
        ["E[backing of winning featured] (ETH)", f"{m_['E_backing_winning_featured']:.3f}"],
        ["median draws to first composition (0.5->1)", f"{m_['median_draws_to_1.0']:.0f}"],
        ["median draws to reach 5 ETH", f"{m_['median_draws_to_5.0']:.0f}" if m_['median_draws_to_5.0'] else "n/a"],
        ["median cycle length (draws to first win)", f"{m_['median_first_win_draw']:.0f}"],
        ["keeper net ETH/draw (0.3 gwei, perDraw 0.0001)", f"{m_['keeper_net_per_draw']:+.2e}"],
    ])
    md += "\n## Backing at which featureds are won\n\n"
    md += table(["backing ETH", "share of wins"],
                [[k, pct(v)] for k, v in m_["win_backing_distribution"].items()])
    md += "\nDays (at 500 draws/day): first composition ~" + \
          f"{m_['median_draws_to_1.0']/500:.1f}d, first win ~{m_['median_first_win_draw']/500:.1f}d.\n"
    # time series CSV
    with open(os.path.join(RESULTS, "lifecycle_timeseries.csv"), "w") as f:
        f.write("draw,mean_surplus,mean_growthFund,mean_keeperBudget,mean_featured_backing\n")
        for i in range(len(r.ts_draw)):
            f.write(f"{r.ts_draw[i]:.0f},{r.ts_surplus[i]:.6f},{r.ts_growth[i]:.6f},"
                    f"{r.ts_keeper_budget[i]:.6f},{r.ts_feat_backing[i]:.4f}\n")
    _w("lifecycle", md, m_)


def sweep_params(args):
    """Vary one game parameter at a time; report price, growth and reach."""
    base = m.Config()
    paths = args.paths or 2000
    draws = args.draws or 7000
    variants = []
    for mk in [10_500, 10_750, 11_000, 11_500, 12_000]:
        variants.append((f"markup {mk/100:.1f}%", m.Config(game=m.GameParams(markupBps=mk))))
    for dp in [200, 377, 800, 1500]:
        variants.append((f"decayPpm {dp}", m.Config(game=m.GameParams(decayPpm=dp))))
    for fl in [500, 1000, 2000]:
        variants.append((f"floorBps {fl}", m.Config(game=m.GameParams(floorBps=fl))))
    for rs in [5000, 7000, 9000]:
        variants.append((f"resetShare {rs}", m.Config(game=m.GameParams(resetShareBps=rs))))
    for sn in [5000, 7500, 10000]:
        variants.append((f"startNotional {sn}", m.Config(game=m.GameParams(startNotionalBps=sn))))

    rows, data = [], {}
    for label, cfg in variants:
        live0 = np.array([t.target for t in cfg.tiers], float)
        seed_n = m.denom(cfg.game.seedIndex) * cfg.game.startNotionalBps / m.BPS
        H = m.board_H(cfg, live0, seed_n)
        allin = m.all_in_price(H, 0.3, 1)["total"]
        r = m.simulate(cfg, gas_gwei=0.3, n_paths=paths, n_draws=draws, seed=args.seed)
        mm = _lifecycle_metrics(r)
        rows.append([label, f"{allin:.5f}", f"{mm['median_draws_to_1.0']:.0f}" if mm['median_draws_to_1.0'] else "-",
                     pct(mm["won_before_first_comp"]), pct(mm["P_reach_5.0_before_won"]),
                     f"{mm['E_backing_winning_featured']:.2f}" if mm['E_backing_winning_featured'] else "-"])
        data[label] = {"all_in_0.3gwei": allin, **mm}
    md = "# Parameter sweep (0.3 gwei, " + f"{paths} paths x {draws} draws)\n\n"
    md += table(["variant", "all-in @0.3gwei", "draws->1ETH", "P(won@0.5)", "P(reach5)", "E[win backing]"], rows)
    _w("params", md, data)


def sweep_board(args):
    """Vary board composition and featured seed denomination."""
    paths = args.paths or 2000
    draws = args.draws or 7000
    T = m.Tier
    boards = {
        "default 50/35/10/4": m.DEFAULT_TIERS,
        "no packs (85/0/10/4)": (T(0.01, 0, 85), T(0.05, 0, 10), T(0.10, 0, 4)),
        "fewer 0.01 (30/35/10/4)": (T(0.01, 0, 30), T(0.03, 3, 35), T(0.05, 0, 10), T(0.10, 0, 4)),
        "more 0.01 (80/35/10/4)": (T(0.01, 0, 80), T(0.03, 3, 35), T(0.05, 0, 10), T(0.10, 0, 4)),
        "shallow (25/15/6/2)": (T(0.01, 0, 25), T(0.03, 3, 15), T(0.05, 0, 6), T(0.10, 0, 2)),
    }
    rows, data = [], {}
    for label, tiers in boards.items():
        cfg = m.Config(tiers=tiers)
        live0 = np.array([t.target for t in cfg.tiers], float)
        seed_n = m.denom(cfg.game.seedIndex) * cfg.game.startNotionalBps / m.BPS
        H = m.board_H(cfg, live0, seed_n)
        allin = m.all_in_price(H, 0.3, 1)["total"]
        board_cost = float(np.sum(live0 * np.array([t.cost(cfg.mint_fee) for t in cfg.tiers])))
        funding = board_cost + m.denom(cfg.game.seedIndex) + cfg.mint_fee + cfg.game.reserveTarget
        p_ord, _ = m.select_probs(cfg, live0, seed_n)
        step_draws = (cfg.game.repriceStepBps/m.BPS)*m.denom(cfg.game.seedIndex)/(m.denom(cfg.game.seedIndex)*cfg.game.decayPpm/m.PPM)
        kgas = m.keeper_gas_per_draw(cfg, p_ord, 0.0, step_draws)
        r = m.simulate(cfg, gas_gwei=0.3, n_paths=paths, n_draws=draws, seed=args.seed)
        mm = _lifecycle_metrics(r)
        rows.append([label, f"{funding:.3f}", f"{allin:.5f}", f"{kgas/1e3:.0f}k",
                     f"{mm['median_draws_to_1.0']:.0f}" if mm['median_draws_to_1.0'] else "-",
                     pct(mm["P_reach_5.0_before_won"])])
        data[label] = {"min_funding": funding, "all_in_0.3gwei": allin, "keeper_gas_per_draw": kgas, **mm}
    # seed denomination 0.1/0.5/1
    srows = []
    for si, name in [(2, "0.1"), (3, "0.5"), (4, "1.0")]:
        cfg = m.Config(game=m.GameParams(seedIndex=si))
        live0 = np.array([t.target for t in cfg.tiers], float)
        seed_n = m.denom(si) * cfg.game.startNotionalBps / m.BPS
        H = m.board_H(cfg, live0, seed_n)
        r = m.simulate(cfg, gas_gwei=0.3, n_paths=paths, n_draws=draws, seed=args.seed)
        mm = _lifecycle_metrics(r)
        p_feat = m.select_probs(cfg, live0, seed_n)[1]
        srows.append([name, f"{m.all_in_price(H,0.3,1)['total']:.5f}", f"{p_feat:.2e}",
                      pct(mm["won_before_first_comp"]), f"{mm['E_backing_winning_featured']:.2f}" if mm['E_backing_winning_featured'] else "-"])
        data[f"seed_{name}"] = mm
    md = "# Board composition & seed sweep (0.3 gwei)\n\n"
    md += table(["board", "min funding ETH", "all-in @0.3gwei", "keeper gas/draw", "draws->1ETH", "P(reach5)"], rows)
    md += "\n## Featured seed denomination\n\n"
    md += table(["seed ETH", "all-in @0.3gwei", "P(featured)/draw @seed", "P(won@seed)", "E[win backing]"], srows)
    _w("board", md, data)


def sweep_volume(args):
    """Time-axis and keeper-flat metrics across daily volume. Per-draw economics
    are volume-independent; only days and the flat-reward burden change."""
    cfg = m.Config()
    # reuse one MC for draws-to-stage (volume-independent), then scale to days
    r = m.simulate(cfg, gas_gwei=0.3, n_paths=args.paths or 2000, n_draws=args.draws or 9000, seed=args.seed)
    mm = _lifecycle_metrics(r)
    d1 = mm["median_draws_to_1.0"]; d5 = mm["median_draws_to_5.0"]; dwin = mm["median_first_win_draw"]
    rows = []
    for v in VOLUMES:
        dt = 86400.0/v
        flat = cfg.keeper.flatReward if dt >= 600 else cfg.keeper.flatReward*dt/600.0
        rows.append([f"{v}", f"{d1/v:.1f}" if d1 else "-", f"{d5/v:.0f}" if d5 else "-",
                     f"{dwin/v:.0f}" if dwin else "-", f"{flat:.6f}",
                     pct(flat/cfg.keeper.perDraw)])
    md = "# Daily-volume sweep (recommended config)\n\n"
    md += "Per-delivered-draw economics do not depend on volume; volume sets the calendar and the "
    md += "flat-reward burden (0.0002 ETH at most per 600s, which dominates at low volume).\n\n"
    md += table(["draws/day", "days->1ETH", "days->5ETH", "days->first win", "flat/draw ETH", "flat vs perDraw"], rows)
    md += "\n### Multi-week inactivity\n\nNo draws => no decay, no surplus, no keeper accrual; the board and "
    md += "featured simply wait. On resumption, play continues from the same state (FWA inventory version "
    md += "only bumps on list/reprice/withdraw, not on idling). Bursts up to 5 draws/tx and 10 outstanding "
    md += "requests/pool are absorbed by prompt booking; beyond maxPendingDraws(30) the gate pauses buying "
    md += "until the keeper books.\n"
    _w("volume", md, {"median_draws_to_1": d1, "median_draws_to_5": d5, "median_first_win_draw": dwin})


def sweep_longrun(args):
    """Long horizon to observe reach-50/100 and repeated large wins."""
    cfg = m.Config()
    r = m.simulate(cfg, gas_gwei=0.3, draws_per_day=2000,
                   n_paths=args.paths or 1000, n_draws=args.draws or 60000, seed=args.seed)
    mm = _lifecycle_metrics(r)
    rows = []
    for s in [1.0, 5.0, 10.0, 50.0, 100.0]:
        dts = r.draws_to_stage[s][r.draws_to_stage[s] >= 0]
        rows.append([f"{s}", pct(r.reached[s].mean()),
                     f"{np.median(dts):.0f}" if len(dts) else "-",
                     f"{np.median(dts)/2000:.0f}" if len(dts) else "-"])
    md = "# Long-horizon reach (0.3 gwei, 2000 draws/day, " + f"{r.n_paths}x{r.n_draws})\n\n"
    md += "'P(reach before won)' is for the FIRST featured of each path. Reaching 50/100 requires the "
    md += "featured to survive uncomposed-by-win across tens of thousands of draws, which is rare.\n\n"
    md += table(["backing ETH", "P(reach before won)", "median draws to reach", "days @2000/day"], rows)
    md += f"\nMean featured wins per path over {r.n_draws} draws: {mm['cycles_won_mean']:.1f}. "
    md += f"E[backing of winning featured]: {mm['E_backing_winning_featured']:.2f} ETH.\n"
    md += "\n## 10->50 stagnation\n\n10->50 needs 40.004 ETH of growth. At ~0.00235 ETH/draw that is ~" + \
          f"{40.004/0.00235:,.0f} draws (~{40.004/0.00235/2000:.0f} days at 2000/day). The 10->50 and "
    md += "50->100 steps are fixed by the Shapes ladder, so the only lever is the growth RATE (higher "
    md += "markup) or accepting that 50/100 are rare, multi-year outcomes.\n"
    _w("longrun", md, mm)


SWEEPS = {
    "static": sweep_static, "price": sweep_price, "keeper": sweep_keeper,
    "lifecycle": sweep_lifecycle, "params": sweep_params, "board": sweep_board,
    "volume": sweep_volume, "longrun": sweep_longrun,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sweeps", nargs="+", help="names or 'all'")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--paths", type=int, default=0)
    ap.add_argument("--draws", type=int, default=0)
    args = ap.parse_args()
    args.paths = args.paths or 0
    args.draws = args.draws or 0
    names = list(SWEEPS) if args.sweeps == ["all"] else args.sweeps
    for n in names:
        if n not in SWEEPS:
            print(f"unknown sweep: {n}; known: {list(SWEEPS)}")
            continue
        print(f"== {n} ==")
        SWEEPS[n](args)


if __name__ == "__main__":
    main()
