"""Per-cell diagnosis of the object-free (terrain-only) passability residual.

WHY THIS EXISTS
===============
`passlatticecheck.py` measures the residual: at 45S82E, object-free, in the vanilla play area,
outside massifs, surface 1,121 of 79,647 samples differ and the UNTOUCHED underground 706 of
79,483.  The user amendment sets the target at ZERO and forbids absorbing either number as
noise: every differing cell must be accounted for, and a quantization claim has to be shown per
cell ("the pre-round slope sitting on the threshold"), not asserted in aggregate.

WHAT IT DOES
============
1. MEASURES the engine's terrain passability threshold instead of assuming it.  For each lattice
   sample it computes candidate statistics on that map's own dumped height grid and picks the
   threshold that best reproduces the engine's own `IsPassable` verdict.  The winning statistic
   on every dumped grid measured so far is

       stat(tile) = max |dh| over the 4 edges of the height-grid quad containing the tile,
       impassable  iff  stat >= T,      T = 27 wu per 100 wu tile  (~15.1 deg)

   with the passable fraction stepping 82% -> 38% exactly at 27 on all four grids.  The rule is
   an approximation of a native computation (residual misclassification ~1% underground, ~3-4%
   surface, dominated by cells the engine calls impassable while their own quad is gentle - a
   neighbourhood/erosion effect), so the report always carries its own error rate.

2. ACCOUNTS FOR EVERY DIFFERING CELL with the vanilla stat Sv and the expanded stat Se read off
   the two dumped grids at the paired positions:

     crossing_smoothing      Sv and Se straddle T and |Sv - Se| > QUANT_BAND  ->  the discrete
                             slope really shrank; not a rounding effect.
     crossing_quantization   they straddle T but |Sv - Se| <= QUANT_BAND      ->  the amendment's
                             quantization case, and it is now shown per cell.
     no_crossing             Sv and Se lie on the SAME side of T -> the own-quad slope does not
                             explain this cell; reported separately, never absorbed.

3. TESTS THE MECHANISM per differing cell.  A 4/3 similarity preserves world slope, but the
   engine reads slope as a DIFFERENCE BETWEEN ADJACENT GRID SAMPLES, and the expanded grid
   samples the same terrain on a 3/4-spaced lattice through an interpolant: adjacent expanded
   nodes are 75 source wu apart, so their difference is a local average of the source
   differences and can only shrink where the source has one-cell-scale structure.  The model
   resamples the VANILLA grid bilinearly at the expanded node positions, applies the map's own
   stamped affine, and recomputes the statistic; agreement with the measured Se is reported.

4. C2a - THE PASS-GRID SPACING MODEL (iter 025).  Iter 024 measured that the twins do not
   evaluate passability on similar lattices: the effective pass cell is `mapsize/PassMapSize`,
   75 wu on vanilla and 50 wu on the expanded map (= 37.5 SOURCE wu, where an exact similarity
   needs 100).  This section recomputes each twin's expected verdict by differencing that twin's
   own BILINEAR height field over its OWN pass cell instead of over height-grid nodes, in two
   alignments (cell corners on multiples of the cell, and cell centres), and reports:
     - the threshold that best reproduces that twin's own engine verdicts, in wu per pass cell
       (absolute) and in wu per 100 wu (normalized by cell size);
     - whether the model beats the height-node model at reproducing the engine;
     - how many of the engine's paired diffs it predicts, in the right direction, against how
       many it invents (false alarms), versus the same numbers for the height-node model.
   An engine rule that is ABSOLUTE per pass cell would show the same absolute threshold on both
   twins and would make the expanded map systematically more permissive; a NORMALIZED rule shows
   the same normalized threshold and can only act near the threshold.  The measurement decides
   which, per twin, from the engine's own verdicts.

Usage:
  python passcelldiag.py <vanilla_tag> <expanded_tag> <zones_txt|-> <out_json>
                         [--threshold 2400] [--dump-dir DIR] [--quant 2]
                         [--pass-cell-vanilla 75] [--pass-cell-expanded 50]
"""
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

import passlatticecheck as P
import zverdict

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
TILE = 100
DEFAULT_OBJ_THRESHOLD = 2400
QUANT_BAND = 2      # a per-node +-1 rounding can move a two-node difference by at most 2
PROFILE_LO, PROFILE_HI = 14, 44
# Measured in iter 024 (`artifacts/pass/passforced_t8_45s82e.json`): mapsize / PassMapSize.
PASS_CELL_VANILLA = 75.0
PASS_CELL_EXPANDED = 50.0


def load_grid(path):
    raw = np.fromfile(path, dtype="<u2")
    side = int(round(math.sqrt(raw.size)))
    if side * side != raw.size:
        raise SystemExit(f"{path}: {raw.size} u16 values is not square")
    return raw.reshape((side, side)).astype(np.int64)   # [y, x], validated in iter 021


def quad_edge_max(g):
    """stat[iy, ix] = max |dh| over the 4 edges of the quad with corner nodes (iy,ix)..(iy+1,ix+1).

    A lattice sample at world (x, y) sits at the centre of that quad: ix = x // 100, iy = y // 100.
    """
    v = np.abs(np.diff(g, axis=0))          # (H-1, W) vertical edges
    h = np.abs(np.diff(g, axis=1))          # (H, W-1) horizontal edges
    return np.maximum(np.maximum(v[:, :-1], v[:, 1:]), np.maximum(h[:-1, :], h[1:, :]))


def bilinear(g, fx, fy):
    ix, iy = int(math.floor(fx)), int(math.floor(fy))
    tx, ty = fx - ix, fy - iy
    ix = min(max(ix, 0), g.shape[1] - 2)
    iy = min(max(iy, 0), g.shape[0] - 2)
    return ((1 - tx) * (1 - ty) * g[iy, ix] + tx * (1 - ty) * g[iy, ix + 1]
            + (1 - tx) * ty * g[iy + 1, ix] + tx * ty * g[iy + 1, ix + 1])


def model_expanded_stat(vg, ex_ix, ex_iy, mul, div, add):
    """Predicted expanded stat at expanded quad (ex_ix, ex_iy) from a bilinear resample model.

    Expanded node (X, Y) sits at world (100X, 100Y) = source world (100X*div/mul, ...), i.e. at
    source grid coordinate (X*div/mul, Y*div/mul); the height then takes the map's own affine.
    """
    r = div / mul
    w = np.zeros((3, 3), dtype=np.int64)
    for j in range(3):
        for i in range(3):
            hv = bilinear(vg, (ex_ix + i) * r, (ex_iy + j) * r)
            w[j, i] = math.floor(hv * mul / div) + add
    return int(quad_edge_max(w).max()), int(quad_edge_max(w)[0, 0])


def bilinear_vec(g, fx, fy):
    """Vectorized bilinear sample of the height grid at float NODE coordinates (fx, fy)."""
    ix = np.clip(np.floor(fx).astype(np.int64), 0, g.shape[1] - 2)
    iy = np.clip(np.floor(fy).astype(np.int64), 0, g.shape[0] - 2)
    tx = fx - ix
    ty = fy - iy
    return ((1 - tx) * (1 - ty) * g[iy, ix] + tx * (1 - ty) * g[iy, ix + 1]
            + (1 - tx) * ty * g[iy + 1, ix] + tx * ty * g[iy + 1, ix + 1])


def pass_cell_stat(g, x, y, cell, align):
    """max |dh| over the 4 edges of the PASS cell containing world (x, y), in wu per cell.

    `align` = "corner": cell corners sit on multiples of `cell` (the natural grid a pass map of
    mapsize/cell cells has).  "center": the same lattice shifted half a cell, i.e. the sample's
    cell is centred on a multiple of `cell`.  Heights come from the map's own bilinear height
    field (nodes every 100 wu), which is what `terrain.GetHeight` was validated to be (021).
    """
    off = 0.0 if align == "corner" else cell / 2.0
    px = np.floor((x - off) / cell)
    py = np.floor((y - off) / cell)
    x0 = px * cell + off
    y0 = py * cell + off
    fx0, fx1 = x0 / TILE, (x0 + cell) / TILE
    fy0, fy1 = y0 / TILE, (y0 + cell) / TILE
    h00 = bilinear_vec(g, fx0, fy0)
    h10 = bilinear_vec(g, fx1, fy0)
    h01 = bilinear_vec(g, fx0, fy1)
    h11 = bilinear_vec(g, fx1, fy1)
    return np.maximum(np.maximum(np.abs(h10 - h00), np.abs(h11 - h01)),
                      np.maximum(np.abs(h01 - h00), np.abs(h11 - h10)))


def sweep_threshold(stat, ps, lo=0.5, hi=90.0, step=0.25):
    """Threshold on a float statistic minimizing disagreement with the engine's own verdict."""
    best = None
    for T in np.arange(lo, hi + step / 2, step):
        err = int(((stat >= T) & (ps == 1)).sum() + ((stat < T) & (ps == 0)).sum())
        if best is None or err < best[1]:
            best = (float(T), err)
    T, err = best
    return {"threshold": round(T, 3), "misclassified": err,
            "misclassified_pct": round(100.0 * err / stat.size, 4) if stat.size else None}


def pooled_threshold(sv, pv, se, pe, lo=0.5, hi=90.0, step=0.25):
    """One rule for BOTH twins: the threshold minimizing total disagreement across them."""
    best = None
    n = sv.size + se.size
    for T in np.arange(lo, hi + step / 2, step):
        err = int(((sv >= T) & (pv == 1)).sum() + ((sv < T) & (pv == 0)).sum()
                  + ((se >= T) & (pe == 1)).sum() + ((se < T) & (pe == 0)).sum())
        if best is None or err < best[1]:
            best = (float(T), err)
    T, err = best
    return {"threshold": round(T, 3), "misclassified": err,
            "misclassified_pct": round(100.0 * err / n, 4) if n else None}


def paired_prediction(sv, se, pv, pe, T):
    """How a rule `impassable iff stat >= T` reproduces the engine's paired disagreements."""
    mv = (sv < T).astype(np.int64)          # model verdict, 1 = passable, like the probe's `p`
    me = (se < T).astype(np.int64)
    eng_diff = pv != pe
    mod_diff = mv != me
    same_dir = eng_diff & mod_diff & ((pv < pe) == (mv < me))
    return {
        "pairs": int(sv.size),
        "engine_diff": int(eng_diff.sum()),
        "engine_f2t": int((eng_diff & (pv == 0)).sum()),
        "model_diff": int(mod_diff.sum()),
        "model_f2t": int((mod_diff & (mv == 0)).sum()),
        "explained_same_direction": int(same_dir.sum()),
        "explained_pct": (round(100.0 * int(same_dir.sum()) / int(eng_diff.sum()), 3)
                          if eng_diff.any() else None),
        "false_alarms": int((mod_diff & ~eng_diff).sum()),
        "false_alarm_rate_pct": round(100.0 * int((mod_diff & ~eng_diff).sum())
                                      / max(1, int((~eng_diff).sum())), 4),
        "model_reproduces_vanilla_pct": round(100.0 * float((mv == pv).mean()), 3),
        "model_reproduces_expanded_pct": round(100.0 * float((me == pe).mean()), 3),
    }


def signed_delta_stats(d, quant):
    if d.size == 0:
        return None
    return {"n": int(d.size), "mean": round(float(d.mean()), 3),
            "median": round(float(np.median(d)), 3),
            "gt_quant_pct": round(100.0 * float((d > quant).mean()), 3),
            "lt_neg_quant_pct": round(100.0 * float((d < -quant).mean()), 3),
            "within_quant_pct": round(100.0 * float((np.abs(d) <= quant).mean()), 3)}


def pass_spacing_model(vg, eg, vrows, erows, pairs, cell_v, cell_e, quant, node_T, dump_path):
    """C2a: each twin judged on ITS OWN pass-cell spacing instead of on height-grid nodes."""
    def inplay_arrays(rows, g):
        rr = [r for r in rows if r["inplay"]]
        x = np.array([r["x"] for r in rr], dtype=np.float64)
        y = np.array([r["y"] for r in rr], dtype=np.float64)
        p = np.array([r["p"] for r in rr], dtype=np.int64)
        ok = (x / TILE < g.shape[1] - 1) & (y / TILE < g.shape[0] - 1)
        return x[ok], y[ok], p[ok]

    vx, vy, vp = inplay_arrays(vrows, vg)
    ex, ey, ep = inplay_arrays(erows, eg)

    # The same pairs the gate scores, as arrays.
    pvx = np.array([v["x"] for v, _ in pairs], dtype=np.float64)
    pvy = np.array([v["y"] for v, _ in pairs], dtype=np.float64)
    pex = np.array([e["x"] for _, e in pairs], dtype=np.float64)
    pey = np.array([e["y"] for _, e in pairs], dtype=np.float64)
    ppv = np.array([v["p"] for v, _ in pairs], dtype=np.int64)
    ppe = np.array([e["p"] for _, e in pairs], dtype=np.int64)
    keep = ((pvx / TILE < vg.shape[1] - 1) & (pvy / TILE < vg.shape[0] - 1)
            & (pex / TILE < eg.shape[1] - 1) & (pey / TILE < eg.shape[0] - 1))
    pvx, pvy, pex, pey, ppv, ppe = (a[keep] for a in (pvx, pvy, pex, pey, ppv, ppe))

    out = {
        "pass_cell_wu": {"vanilla": cell_v, "expanded": cell_e},
        "pass_cell_in_source_wu": {"vanilla": cell_v, "expanded": round(cell_e * 0.75, 3)},
        "alignments": {},
    }
    best_align = None
    for align in ("corner", "center"):
        sv_abs = pass_cell_stat(vg, vx, vy, cell_v, align)
        se_abs = pass_cell_stat(eg, ex, ey, cell_e, align)
        sv_n = sv_abs * TILE / cell_v
        se_n = se_abs * TILE / cell_e
        rec = {
            "per_twin_absolute_wu_per_cell": {
                "vanilla": sweep_threshold(sv_abs, vp),
                "expanded": sweep_threshold(se_abs, ep),
            },
            "per_twin_normalized_wu_per_100wu": {
                "vanilla": sweep_threshold(sv_n, vp),
                "expanded": sweep_threshold(se_n, ep),
            },
            "pooled_absolute": pooled_threshold(sv_abs, vp, se_abs, ep),
            "pooled_normalized": pooled_threshold(sv_n, vp, se_n, ep),
        }
        # Paired prediction under the pooled NORMALIZED rule (one rule, not per-twin fitted).
        psv = pass_cell_stat(vg, pvx, pvy, cell_v, align) * TILE / cell_v
        pse = pass_cell_stat(eg, pex, pey, cell_e, align) * TILE / cell_e
        T = rec["pooled_normalized"]["threshold"]
        rec["paired_prediction_pooled_normalized"] = paired_prediction(psv, pse, ppv, ppe, T)
        rec["paired_prediction_at_node_threshold"] = paired_prediction(psv, pse, ppv, ppe, node_T)
        eng_diff = ppv != ppe
        rec["stat_delta_on_diffs"] = signed_delta_stats(psv[eng_diff] - pse[eng_diff], quant)
        rec["stat_delta_on_matches"] = signed_delta_stats(psv[~eng_diff] - pse[~eng_diff], quant)
        rec["near_threshold_share_pct"] = round(
            100.0 * float((np.abs(psv - T) <= 8).mean()), 3)
        out["alignments"][align] = rec
        score = (rec["per_twin_normalized_wu_per_100wu"]["vanilla"]["misclassified"]
                 + rec["per_twin_normalized_wu_per_100wu"]["expanded"]["misclassified"])
        if best_align is None or score < best_align[1]:
            best_align = (align, score, psv, pse, eng_diff, T)

    align, _, psv, pse, eng_diff, T = best_align
    out["best_alignment"] = align
    if dump_path is not None and int(eng_diff.sum()):
        sel = np.nonzero(eng_diff)[0]
        head = ["vx", "vy", "ex", "ey", "vanilla_pass", "expanded_pass",
                "pass_stat_vanilla_norm", "pass_stat_expanded_norm", "pooled_threshold",
                "model_vanilla_pass", "model_expanded_pass", "predicts_diff"]
        lines = [",".join(head)]
        for i in sel:
            mv, me = int(psv[i] < T), int(pse[i] < T)
            lines.append(",".join(str(s) for s in [
                int(pvx[i]), int(pvy[i]), int(pex[i]), int(pey[i]), int(ppv[i]), int(ppe[i]),
                round(float(psv[i]), 3), round(float(pse[i]), 3), T, mv, me,
                1 if mv != me else 0]))
        Path(dump_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
        out["per_diff_cell_csv"] = str(dump_path)
    return out


def measure_threshold(stat, ps):
    """Threshold minimizing disagreement with the engine's own verdict, plus its profile."""
    best = None
    for T in range(1, 200):
        err = int(((stat >= T) & (ps == 1)).sum() + ((stat < T) & (ps == 0)).sum())
        if best is None or err < best[1]:
            best = (T, err)
    T, err = best
    profile = []
    for s in range(PROFILE_LO, PROFILE_HI + 1):
        sel = stat == s
        n = int(sel.sum())
        if n:
            profile.append({"stat": s, "n": n, "passable": int(ps[sel].sum()),
                            "passable_pct": round(100.0 * ps[sel].mean(), 2)})
    return {
        "threshold_wu_per_tile": T,
        "threshold_deg": round(math.degrees(math.atan2(T, TILE)), 3),
        "samples": int(ps.size),
        "misclassified": err,
        "misclassified_pct": round(100.0 * err / ps.size, 4) if ps.size else None,
        "passable_above_T": int(((stat >= T) & (ps == 1)).sum()),
        "impassable_below_T": int(((stat < T) & (ps == 0)).sum()),
        "profile": profile,
    }


def pair_samples(vrows, erows, massifs, obj_threshold):
    """The scored set of `passlatticecheck.score_map`, kept as pairs for per-cell work."""
    vidx = {(r["sgx"], r["sgy"]): r for r in vrows}
    pairs = []
    for e in erows:
        v = vidx.get((e["sgx"], e["sgy"]))
        if v is None:
            continue
        if v["dmin_src"] < obj_threshold or e["dmin_src"] < obj_threshold:
            continue
        if not v["inplay"]:
            continue
        cx, cy = e["x"] // TILE, e["y"] // TILE
        if any(x0 <= cx <= x1 and y0 <= cy <= y1 for x0, y0, x1, y1 in massifs):
            continue
        pairs.append((v, e))
    return pairs


def diagnose(env, vtag, etag, massifs, stamp, obj_threshold, quant, dump_dir,
             cell_v=PASS_CELL_VANILLA, cell_e=PASS_CELL_EXPANDED):
    vg = load_grid(OUT / f"height-{vtag}-{env}.raw")
    eg = load_grid(OUT / f"height-{etag}-{env}.raw")
    vstat, estat = quad_edge_max(vg), quad_edge_max(eg)

    vrows, vmeta = P.read_lattice(OUT / f"passlat-{vtag}.csv")
    erows, emeta = P.read_lattice(OUT / f"passlat-{etag}.csv")
    em = emeta.get(env, {})
    mul = int(em.get("zmul") or 8192)
    div = int(em.get("zdiv") or 6144)
    add = int(em.get("zadd") or 0)

    # (1) the engine's threshold, measured separately on each twin's own grid and verdicts.
    def measured(rows, stat, key):
        rr = [r for r in rows[env] if r["inplay"]]
        ix = np.array([r["x"] // TILE for r in rr])
        iy = np.array([r["y"] // TILE for r in rr])
        ok = (ix < stat.shape[1]) & (iy < stat.shape[0])
        ps = np.array([r["p"] for r in rr])[ok]
        out = measure_threshold(stat[iy[ok], ix[ok]], ps)
        out["twin"] = key
        return out

    thr = {"vanilla": measured(vrows, vstat, vtag), "expanded": measured(erows, estat, etag)}
    T = thr["vanilla"]["threshold_wu_per_tile"]

    # (2) per-cell accounting over the same scored set the gate reports.
    pairs = pair_samples(vrows[env], erows[env], massifs, obj_threshold)
    classes = Counter()
    consistency = Counter()
    rows_out = []
    dSv_diff, dSv_same = [], []
    sv_hist = Counter()
    by_sv = defaultdict(lambda: [0, 0])      # |Sv - T| bucket -> [n, diff]
    model_ok = model_pred_ok = model_n = 0
    diff = f2t = t2f = 0
    for v, e in pairs:
        vix, viy = v["x"] // TILE, v["y"] // TILE
        eix, eiy = e["x"] // TILE, e["y"] // TILE
        if vix >= vstat.shape[1] or viy >= vstat.shape[0]:
            continue
        if eix >= estat.shape[1] or eiy >= estat.shape[0]:
            continue
        sv, se = int(vstat[viy, vix]), int(estat[eiy, eix])
        # How far the vanilla tile's own slope sits from the measured threshold: the amendment's
        # "pre-round slope on the threshold" is a statement about THIS distance.
        band = max(-40, min(sv - T, 40))
        by_sv[band][0] += 1
        by_sv[band][1] += 1 if v["p"] != e["p"] else 0
        if v["p"] == e["p"]:
            dSv_same.append(sv - se)
            continue
        # Does the measured rule reproduce each twin's own engine verdict at this cell?
        consistency["v_rule_ok" if (sv >= T) == (v["p"] == 0) else "v_rule_wrong"] += 1
        consistency["e_rule_ok" if (se >= T) == (e["p"] == 0) else "e_rule_wrong"] += 1
        if (sv >= T) == (v["p"] == 0) and (se >= T) == (e["p"] == 0):
            consistency["both_rule_ok"] += 1
        diff += 1
        one_way = v["p"] == 0
        f2t += 1 if one_way else 0
        t2f += 0 if one_way else 1
        dSv_diff.append(sv - se)
        sv_hist[min(sv, 60)] += 1
        straddle = (sv >= T) != (se >= T)
        if straddle and abs(sv - se) > quant:
            cls = "crossing_smoothing"
        elif straddle:
            cls = "crossing_quantization"
        else:
            cls = "no_crossing"
        classes[f"{cls}|{'f2t' if one_way else 't2f'}"] += 1
        # (3) mechanism model: does a bilinear resample of the VANILLA grid predict Se?
        m_max, m_own = model_expanded_stat(vg, eix, eiy, mul, div, add)
        model_n += 1
        if abs(m_own - se) <= quant:
            model_ok += 1
        if (m_own >= T) == (se >= T):
            model_pred_ok += 1
        rows_out.append({
            "sgx": v["sgx"], "sgy": v["sgy"], "vx": v["x"], "vy": v["y"],
            "ex": e["x"], "ey": e["y"], "vanilla_pass": v["p"], "expanded_pass": e["p"],
            "stat_vanilla": sv, "stat_expanded": se, "stat_model": m_own,
            "threshold": T, "class": cls,
        })

    if dump_dir and rows_out:
        d = Path(dump_dir)
        d.mkdir(parents=True, exist_ok=True)
        head = list(rows_out[0].keys())
        lines = [",".join(head)]
        lines += [",".join(str(r[k]) for k in head) for r in rows_out]
        (d / f"passcelldiag-{env}-{vtag}-{etag}.csv").write_text("\n".join(lines) + "\n",
                                                                encoding="utf-8")

    def stats_of(a):
        if not a:
            return None
        arr = np.array(a)
        return {"n": int(arr.size), "mean": round(float(arr.mean()), 3),
                "median": int(np.median(arr)), "min": int(arr.min()), "max": int(arr.max()),
                "gt_quant_pct": round(100.0 * float((arr > quant).mean()), 3),
                "lt_neg_quant_pct": round(100.0 * float((arr < -quant).mean()), 3),
                "within_quant_pct": round(100.0 * float((np.abs(arr) <= quant).mean()), 3)}

    accounted = sum(n for k, n in classes.items() if k.startswith("crossing_"))

    # C2a: the same scored pairs judged on each twin's OWN pass-cell spacing, plus the
    # height-node model's paired prediction as the baseline to beat.
    def node_pair_arrays():
        sv, se, pv, pe = [], [], [], []
        for v, e in pairs:
            vix, viy = v["x"] // TILE, v["y"] // TILE
            eix, eiy = e["x"] // TILE, e["y"] // TILE
            if vix >= vstat.shape[1] or viy >= vstat.shape[0]:
                continue
            if eix >= estat.shape[1] or eiy >= estat.shape[0]:
                continue
            sv.append(vstat[viy, vix])
            se.append(estat[eiy, eix])
            pv.append(v["p"])
            pe.append(e["p"])
        return (np.array(sv, dtype=np.float64), np.array(se, dtype=np.float64),
                np.array(pv, dtype=np.int64), np.array(pe, dtype=np.int64))

    nsv, nse, npv, npe = node_pair_arrays()
    node_baseline = paired_prediction(nsv, nse, npv, npe, T) if nsv.size else None
    dump_csv = (Path(dump_dir) / f"passcellmodel-{env}-{vtag}-{etag}.csv") if dump_dir else None
    pass_model = pass_spacing_model(vg, eg, vrows[env], erows[env], pairs,
                                    cell_v, cell_e, quant, T, dump_csv)
    pass_model["height_node_model_baseline"] = node_baseline

    return {
        "env": env, "scored_pairs": len(pairs), "diff": diff,
        "false_to_true": f2t, "true_to_false": t2f,
        "diff_rate_pct": round(100.0 * diff / len(pairs), 4) if pairs else None,
        "threshold_measurement": thr,
        "quant_band_wu": quant,
        "classes": dict(sorted(classes.items())),
        "rule_consistency_on_diffs": dict(sorted(consistency.items())),
        "diff_rate_by_signed_distance_from_threshold": {
            str(k): {"n": v[0], "diff": v[1],
                     "diff_rate_pct": round(100.0 * v[1] / v[0], 4) if v[0] else None}
            for k, v in sorted(by_sv.items())},
        "accounted_by_threshold_crossing": accounted,
        "accounted_pct": round(100.0 * accounted / diff, 3) if diff else None,
        "stat_delta_on_diffs": stats_of(dSv_diff),
        "stat_delta_on_matches": stats_of(dSv_same),
        "vanilla_stat_hist_on_diffs": dict(sorted(sv_hist.items())),
        "resample_model": {
            "cells": model_n,
            "stat_within_quant": model_ok,
            "stat_within_quant_pct": round(100.0 * model_ok / model_n, 3) if model_n else None,
            "side_of_threshold_agrees": model_pred_ok,
            "side_of_threshold_agrees_pct": (round(100.0 * model_pred_ok / model_n, 3)
                                             if model_n else None),
        },
        "pass_spacing_model": pass_model,
        "affine": {"mul": mul, "div": div, "add": add},
        "grids": {"vanilla": list(vg.shape), "expanded": list(eg.shape)},
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a.split("=", 1)[0]: (a.split("=", 1)[1] if "=" in a else True)
             for a in sys.argv[1:] if a.startswith("--")}
    if len(args) < 4:
        raise SystemExit(__doc__)
    vtag, etag, zones_txt, out_json = args[:4]
    obj_threshold = int(flags.get("--threshold", DEFAULT_OBJ_THRESHOLD))
    quant = int(flags.get("--quant", QUANT_BAND))
    cell_v = float(flags.get("--pass-cell-vanilla", PASS_CELL_VANILLA))
    cell_e = float(flags.get("--pass-cell-expanded", PASS_CELL_EXPANDED))
    dump_dir = flags.get("--dump-dir")
    stamp = {} if zones_txt == "-" else zverdict.read_stamp(zones_txt)

    result = {"vanilla": vtag, "expanded": etag, "zones": zones_txt,
              "object_threshold_src_wu": obj_threshold, "maps": {}}
    for env in ("underground", "surface"):
        if not (OUT / f"height-{vtag}-{env}.raw").exists():
            continue
        massifs = (stamp.get(env) or {}).get("massifs", [])
        result["maps"][env] = diagnose(env, vtag, etag, massifs, stamp.get(env),
                                       obj_threshold, quant,
                                       dump_dir if dump_dir is not True else None,
                                       cell_v, cell_e)
        result["maps"][env]["massifs"] = len(massifs)
    Path(out_json).write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
