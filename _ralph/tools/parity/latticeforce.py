"""C2 - per-cell: is each object-free passability difference FORCED by the resample lattice?

THE MECHANISM UNDER TEST
========================
Both maps carry a 100 wu height tile, so the engine's slope statistic (max |dh| over the 4 edges
of the containing quad) is already in the same units on both - a 4/3 similarity preserves it
exactly for any locally linear ground.  What it does NOT preserve is SAMPLING: an expanded node
step of 100 expanded wu is 75 SOURCE wu, so the expanded grid reads the same terrain on a 3/4
lattice through an interpolant.  Interpolation is a low-pass filter: a one-cell-wide vanilla
step of D is split across two expanded edges unless it happens to fall in the 1-of-3 phase that
keeps an expanded edge inside it, so the expanded statistic lands between (2/3)D and D - never
above.  That is inherently ONE-WAY false->true and concentrated near the threshold, which is the
observed signature (869:252, 72% of diffs within |Sv-T| <= 8, contours disagree while bodies
coincide).

WHAT DECIDES IT
===============
Three statistics at every scored pair, all in wu per 100 wu, all read at the same ground:

  Sv  vanilla, from the vanilla dumped grid
  Se  expanded, from the expanded dumped grid (what the engine actually judged)
  Si  IDEAL similarity: the vanilla grid resampled analytically at the expanded node positions
      (centre-aligned bilinear, the alignment measured by `resamplefit.py`) and put
      through the map's own stamped affine - i.e. what a mathematically perfect 4/3 similarity
      of the vanilla terrain WOULD produce on the expanded lattice.

Each differing cell is then one of:

  forced_by_lattice   the ideal similarity crosses the threshold too (Sv and Si on opposite
                      sides) -> mathematically forced; no implementation can avoid it while the
                      expanded height grid has 4/3 as many nodes over the same ground.
  kernel_extra        the ideal does NOT cross but the engine's resample does (Si and Se on
                      opposite sides) -> caused by the engine's resample kernel being smoother
                      than the ideal, not by the lattice; potentially fixable.
  unexplained         neither -> the slope statistic does not account for this cell.

Usage:
  python latticeforce.py <vanilla_tag> <expanded_tag> <zones_txt> <out_json>
                                  [--threshold 2400] [--slope-threshold 27] [--shift -0.125]
                                  [--dump-dir DIR] [--env surface]
"""
import json
import math
import sys
from collections import Counter
from pathlib import Path

import numpy as np

import passlatticecheck as P
import passcelldiag as D    
import zverdict             

OUT = Path(__file__).resolve().parent / "out"
TILE = 100


def load_grid(path):
    raw = np.fromfile(path, dtype="<u2")
    side = int(round(math.sqrt(raw.size)))
    return raw.reshape((side, side)).astype(np.float64)      # [y, x]


def quad_edge_max(g):
    v = np.abs(np.diff(g, axis=0))
    h = np.abs(np.diff(g, axis=1))
    return np.maximum(np.maximum(v[:, :-1], v[:, 1:]), np.maximum(h[:-1, :], h[1:, :]))


def bilinear(g, fx, fy):
    ix = np.clip(np.floor(fx).astype(np.int64), 0, g.shape[1] - 2)
    iy = np.clip(np.floor(fy).astype(np.int64), 0, g.shape[0] - 2)
    tx, ty = fx - ix, fy - iy
    return ((1 - tx) * (1 - ty) * g[iy, ix] + tx * (1 - ty) * g[iy, ix + 1]
            + (1 - tx) * ty * g[iy + 1, ix] + tx * ty * g[iy + 1, ix + 1])


def ideal_stat(vg, ex_ix, ex_iy, mul, div, add, shift):
    """Si at the expanded quad with corner node (ex_ix, ex_iy), from the vanilla grid."""
    r = div / mul
    vals = []
    for j in (0, 1):
        row = []
        for i in (0, 1):
            fx = (ex_ix + i) * r + shift
            fy = (ex_iy + j) * r + shift
            row.append(np.floor(bilinear(vg, fx, fy) * mul / div) + add)
        vals.append(row)
    e1 = np.abs(vals[0][1] - vals[0][0])
    e2 = np.abs(vals[1][1] - vals[1][0])
    e3 = np.abs(vals[1][0] - vals[0][0])
    e4 = np.abs(vals[1][1] - vals[0][1])
    return np.maximum(np.maximum(e1, e2), np.maximum(e3, e4))


def hist_summary(a, T):
    return {"n": int(a.size), "mean": round(float(a.mean()), 3),
            "median": float(np.median(a)), "p90": float(np.percentile(a, 90)),
            "ge_T_pct": round(100.0 * float((a >= T).mean()), 4)}


def run_env(env, vtag, etag, stamp, obj_threshold, T, shift, dump_dir):
    vg = load_grid(OUT / f"height-{vtag}-{env}.raw")
    eg = load_grid(OUT / f"height-{etag}-{env}.raw")
    st = stamp.get(env) or {}
    mul, div, add = int(st["mul"]), int(st["div"]), int(st["add"])
    massifs = st.get("massifs") or []
    vstat, estat = quad_edge_max(vg), quad_edge_max(eg)

    vrows, _ = P.read_lattice(OUT / f"passlat-{vtag}.csv")
    erows, _ = P.read_lattice(OUT / f"passlat-{etag}.csv")
    pairs = D.pair_samples(vrows[env], erows[env], massifs, obj_threshold)

    vix = np.array([v["x"] // TILE for v, _ in pairs], dtype=np.int64)
    viy = np.array([v["y"] // TILE for v, _ in pairs], dtype=np.int64)
    eix = np.array([e["x"] // TILE for _, e in pairs], dtype=np.int64)
    eiy = np.array([e["y"] // TILE for _, e in pairs], dtype=np.int64)
    pv = np.array([v["p"] for v, _ in pairs], dtype=np.int64)
    pe = np.array([e["p"] for _, e in pairs], dtype=np.int64)
    sgx = np.array([v["sgx"] for v, _ in pairs], dtype=np.int64)
    sgy = np.array([v["sgy"] for v, _ in pairs], dtype=np.int64)
    ok = ((vix < vstat.shape[1]) & (viy < vstat.shape[0])
          & (eix < estat.shape[1]) & (eiy < estat.shape[0]))
    vix, viy, eix, eiy, pv, pe, sgx, sgy = (a[ok] for a in
                                            (vix, viy, eix, eiy, pv, pe, sgx, sgy))

    Sv = vstat[viy, vix]
    Se = estat[eiy, eix]
    Si = ideal_stat(vg, eix.astype(np.float64), eiy.astype(np.float64), mul, div, add, shift)

    out = {"env": env, "affine": {"mul": mul, "div": div, "add": add},
           "massifs": len(massifs), "shift_source_cells": shift,
           "slope_threshold_wu_per_100wu": T, "pairs": int(Sv.size),
           "statistic_distributions": {"vanilla_Sv": hist_summary(Sv, T),
                                       "expanded_measured_Se": hist_summary(Se, T),
                                       "ideal_similarity_Si": hist_summary(Si, T)},
           "attenuation": {
               "mean_Sv_minus_Si": round(float((Sv - Si).mean()), 4),
               "mean_Sv_minus_Se": round(float((Sv - Se).mean()), 4),
               "mean_Si_minus_Se": round(float((Si - Se).mean()), 4),
               "Si_le_Sv_pct": round(100.0 * float((Si <= Sv).mean()), 3),
               "Se_le_Sv_pct": round(100.0 * float((Se <= Sv).mean()), 3),
               "ratio_Si_over_Sv_mean_on_steep": round(
                   float((Si[Sv >= T] / np.maximum(Sv[Sv >= T], 1)).mean()), 4),
               "ratio_Se_over_Sv_mean_on_steep": round(
                   float((Se[Sv >= T] / np.maximum(Sv[Sv >= T], 1)).mean()), 4),
           }}

    diff = pv != pe
    cls = Counter()
    rows = []
    for i in np.nonzero(diff)[0]:
        sv, se, si = float(Sv[i]), float(Se[i]), float(Si[i])
        lattice_crosses = (sv >= T) != (si >= T)
        kernel_crosses = (si >= T) != (se >= T)
        if lattice_crosses:
            c = "forced_by_lattice"
        elif kernel_crosses:
            c = "kernel_extra"
        else:
            c = "unexplained"
        # Does the crossing go the same way as the engine's own disagreement?
        direction = "f2t" if pv[i] == 0 else "t2f"
        cls[f"{c}|{direction}"] += 1
        rows.append({"sgx": int(sgx[i]), "sgy": int(sgy[i]),
                     "vx": int(vix[i]) * TILE, "vy": int(viy[i]) * TILE,
                     "ex": int(eix[i]) * TILE, "ey": int(eiy[i]) * TILE,
                     "vanilla_pass": int(pv[i]), "expanded_pass": int(pe[i]),
                     "Sv": sv, "Si": si, "Se": se, "threshold": T, "class": c})
    out["diff"] = int(diff.sum())
    out["false_to_true"] = int((diff & (pv == 0)).sum())
    out["true_to_false"] = int((diff & (pv == 1)).sum())
    out["classes"] = dict(sorted(cls.items()))
    acc = sum(n for k, n in cls.items() if not k.startswith("unexplained"))
    out["accounted"] = acc
    out["accounted_pct"] = round(100.0 * acc / max(1, int(diff.sum())), 3)

    # Calibration: how often does the same threshold rule reproduce each twin's OWN engine
    # verdict?  A per-cell claim is only as good as this number.
    out["rule_reproduces_engine_pct"] = {
        "vanilla": round(100.0 * float(((Sv < T) == (pv == 1)).mean()), 3),
        "expanded_measured": round(100.0 * float(((Se < T) == (pe == 1)).mean()), 3),
        "expanded_from_ideal": round(100.0 * float(((Si < T) == (pe == 1)).mean()), 3),
    }

    if dump_dir:
        d = Path(dump_dir)
        d.mkdir(parents=True, exist_ok=True)
        np.savez_compressed(d / f"latticeforce-{env}-{vtag}-{etag}.npz",
                            Sv=Sv, Si=Si, Se=Se, pv=pv, pe=pe, T=np.array([T]))
    if dump_dir and rows:
        d = Path(dump_dir)
        head = list(rows[0].keys())
        lines = [",".join(head)] + [",".join(str(r[k]) for k in head) for r in rows]
        p = d / f"latticeforce-{env}-{vtag}-{etag}.csv"
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
        out["per_diff_csv"] = str(p)
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a.split("=", 1)[0]: (a.split("=", 1)[1] if "=" in a else True)
             for a in sys.argv[1:] if a.startswith("--")}
    if len(args) < 4:
        raise SystemExit(__doc__)
    vtag, etag, zones_txt, out_json = args[:4]
    obj_threshold = int(flags.get("--threshold", 2400))
    T = float(flags.get("--slope-threshold", 27))
    shift = float(flags.get("--shift", -0.125))
    dump_dir = flags.get("--dump-dir")
    only = flags.get("--env")
    stamp = zverdict.read_stamp(zones_txt)
    res = {"vanilla": vtag, "expanded": etag, "zones": zones_txt,
           "object_threshold_src_wu": obj_threshold, "maps": {}}
    for env in ("underground", "surface"):
        if only and only is not True and env != only:
            continue
        if not (OUT / f"height-{vtag}-{env}.raw").exists():
            continue
        res["maps"][env] = run_env(env, vtag, etag, stamp, obj_threshold, T, shift,
                                   dump_dir if dump_dir is not True else None)
    Path(out_json).write_text(json.dumps(res, indent=2), encoding="utf-8")
    print(json.dumps(res, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
