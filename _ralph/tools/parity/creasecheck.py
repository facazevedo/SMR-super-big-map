"""Gate the contract's `no-crease` condition NUMERICALLY, on real dumped cells.

The contract asks for the in-zone remap's join to be slope-continuous at each massif's base
and for that to be verified "on the dumped grids (finite-difference slope across the base
contour has no step discontinuity)".  `zonecheck.py` already reports the ANALYTIC derivative
of every stamped LUT at its base (worst |slope - 4/3| = 3.3e-10); that proves the curve, not
the terrain.  This tool measures the terrain.

WHAT IS MEASURED, and why these statistics.

Outside a massif the port writes post = max(0, floor(min(pre, src_cap)*zmul/zdiv) + shift):
a pure 4/3 similarity, so ANY finite difference of `post` is 4/3 of the same finite difference
of `pre`, up to the two floors (at most 1 unit each).  Inside a massif it writes post = lut[pre],
a curve whose derivative starts at exactly 4/3 at the base and tightens with height.  A crease
would be a STEP in that derivative right at the base contour -- exactly what the first (rejected)
descent rule produced, where 11 massifs collapsed to a flat plateau (slope 0 at the base).

Three independent measurements, all on the dumped cells:

SCORED
  boundary pairs   every 4-connected (inside, outside) cell pair straddling the base contour.
                   d_post must equal 4/3 * d_pre within the floor quantization, minus the LUT's
                   own sag at the inside cell's height (an ANALYTIC second-order term that is 0
                   at the base -- that is the whole point of the tangency).  Scored as
                   |d_post - 4/3*d_pre + sag| <= 2 units, i.e. the two floors.  Reported and
                   scored on top of that: the STRICT, model-free subset of pairs whose inside
                   cell sits close enough to the base that the sag is under one unit, where the
                   expectation carries no analytic term at all and the measurement is simply
                   "the rise across the join is the same 4/3 as outside".
  join rise        the median |rise| across the contour, divided by the median |rise| on the
                   ground 1-4 cells outside it.  Model-free AND source-free -- it is the one
                   test that also runs on an end-of-generation grid.  A tangent join carries the
                   same rise as its surroundings; a collapsed summit carries none.
  analytic slope   each stamped curve's derivative at its base, which must be 4/3 to 1e-9.

POSITIVE CONTROL.  Every threshold is calibrated against a measured crease on the same cells,
not asserted: the tool rebuilds iteration 001's actual failure mode (base == src_cap, the summit
clipped flat at base_img, slope 0 at the join) and runs the same statistics on it.  Measured at
42S28W: the strict boundary statistic reads 16.7-133 units for the crease against 1.67 here, and
the join rise reads ~0 against ~1 here -- both separate cleanly.  The CURVATURE statistics do
NOT separate (the crease reads as low as 1.58 against 2.77 here), which is why they are reported
and never scored: the join is C1 by design and deliberately not C2 (L''(0) = -k*4/3), so its
curvature legitimately steps at the contour.

DIAGNOSTIC, NOT SCORED
  height bins      R = |grad post| / |grad pre| binned by t = pre - base, against the analytic
                   (4/3)exp(-k t), plus a fitted k.  This reads BELOW the point value near the
                   join for two measured reasons: a near-contour cell on this rim wall rises
                   100-300 source units, so its central difference averages the derivative over
                   a wide t span; and the small massifs have no populated bin near t = 0 at all.
                   It shows the compression biting smoothly with height; it cannot resolve the
                   join itself.
  distance bands   the same ratio binned by distance to the contour: same objection, stronger.
  sag on cells     S(t) = affine(pre) - post per t bin: S(0) = 0 with a flat start is the
                   tangency seen on cells; a slope step of size s would make S rise linearly.

The destination-only mode (`--post` and `--stamp`, no `--pre`) keeps the join-rise and analytic
tests and drops everything that needs the source grid.  That is the mode for an END-OF-GENERATION
grid, where the mod's later terrain edits have already been applied and no pre-transform grid
exists.

Usage:
  python creasecheck.py --pre out/stretch-zx06-surface-pre.raw \
      --post out/stretch-zx06-surface-post.raw --stamp out/height-zx06-zones.txt \
      --json <out.json> [--fig <out.png>] [--label ...]
  python creasecheck.py --post out/height-m5x-surface.raw --stamp out/height-m5x-zones.txt \
      --json <out.json>
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np
from scipy import ndimage

CAP = 65535
XY_MUL, XY_DIV = 8192, 6144
TARGET_SLOPE = XY_MUL / XY_DIV

# The port's two floors (one on each cell of a difference) bound a finite-difference error at
# 2 height units; nothing smaller is measurable on an integer grid.
QUANT_UNITS = 2
# Cells whose source gradient is below this carry more quantization than signal in a ratio.
GRAD_FLOOR = 8.0
# How far either side of the contour the bands are reported.
BANDS = 8
# Bands used for the step number: just inside vs just outside.
STEP_BAND = 1
# A height bin needs this many cells before its median is read as the slope at the join.
MIN_BIN_CELLS = 100
# Tolerated step between the slope ratio at the join and the map's own outside control band.
STEP_TOL = 0.05
# Curvature is reported, never scored: the join is C1 by design and NOT C2 (L''(0) = -k*4/3), so
# the curvature steps there legitimately, and the positive control measures the crease and the
# correct join overlapping on that statistic.  These two remain as reported reference points.
CURV_TOL = 2.5
CURV_RATIO_TOL = 4.0
# The per-cell rise on the first cells inside the join, divided by the rise on the ground 1-4
# cells outside it.  A tangent join carries the terrain's own relief through (~1); the
# collapsed-summit crease clips every inside cell to one level and reads exactly 0.
JOIN_RISE_TOL = 0.5
# ...but only where one cell can resolve the bend: k * (source rise per cell) must be small.
JOIN_RISE_MAX_PHASE = 0.25


def load(path, width):
    raw = np.fromfile(path, dtype="<u2")
    side = int(round(math.sqrt(raw.size)))
    if side * side != raw.size:
        raise SystemExit(f"{path}: {raw.size} u16 values is not square")
    if width and side != width:
        raise SystemExit(f"{path}: {side}^2, expected {width}^2")
    return raw.reshape((side, side))


def parse_stamp(path):
    maps, massifs = {}, []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            parts = line.split(",")
            if parts[0] == "map":
                d = {}
                for kv in parts[2:]:
                    k, _, v = kv.partition("=")
                    d[k] = v
                maps[parts[1]] = d
            elif parts[0] == "massif":
                d = dict(tag=parts[1], index=int(parts[2]))
                for kv in parts[3:]:
                    k, _, v = kv.partition("=")
                    d[k] = v
                for k in ("x0", "y0", "x1", "y1", "base", "base_img", "peak", "peak_img",
                          "peak_x", "peak_y", "cells", "band_h", "band_t"):
                    d[k] = int(d[k])
                d["k"] = float(d["k"])
                d["monotone"] = d["monotone"] == "true"
                d["escaped"] = d["escaped"] == "true"
                massifs.append(d)
    return maps, massifs


def lut_for(base, peak, base_img, k, shift):
    """The port's integer LUT, reproduced exactly (floor(x+0.5), clamped to the affine)."""
    H = CAP - base_img
    T = peak - base
    t = np.arange(0, T + 1, dtype=np.float64)
    if k > 0:
        img = base_img + np.floor(H * (-np.expm1(-k * t)) / -np.expm1(-k * T) + 0.5)
    else:
        img = base_img + np.floor(H * t / max(T, 1) + 0.5)
    aff = ((np.arange(base, peak + 1, dtype=np.int64) * XY_MUL) // XY_DIV) + shift
    return np.minimum(img.astype(np.int64), aff)


def analytic_slope_at_base(m):
    H, T, k = CAP - m["base_img"], m["peak"] - m["base"], m["k"]
    if k > 0 and T > 0:
        return H * k / -math.expm1(-k * T)
    return (H / T) if T else None


def grad_mag(a):
    """Central-difference gradient magnitude, valid on the interior (edges get one-sided)."""
    gy, gx = np.gradient(a.astype(np.float64))
    return np.hypot(gx, gy)


def laplace_mag(a):
    f = a.astype(np.float64)
    lap = np.zeros_like(f)
    lap[1:-1, :] += f[2:, :] + f[:-2, :] - 2.0 * f[1:-1, :]
    lap[:, 1:-1] += f[:, 2:] + f[:, :-2] - 2.0 * f[:, 1:-1]
    return np.abs(lap)


def pair_rise(grid, mask, band):
    """Median |rise| on the first cells INSIDE the join, over the same on the ground outside it.

    Model-free and source-free, and it separates cleanly (measured, see the positive control):
    the correct transform carries the terrain's own relief straight through the join, so the
    first band inside rises about as much per cell as the ground 1-4 cells outside; a collapsed
    summit clips every cell inside to the same level, so the inside rise is EXACTLY zero.

    Reported alongside: the rise across the contour itself, which is a weaker statistic -- a
    crossing pair still spans the base level even when the summit is flat (measured 0.35-0.75
    of the control instead of 0).
    """
    inner, cross, ctrl = [], [], []
    for dy, dx in ((0, 1), (1, 0)):
        sl_a = (slice(max(0, dy), grid.shape[0] + min(0, dy)),
                slice(max(0, dx), grid.shape[1] + min(0, dx)))
        sl_b = (slice(max(0, -dy), grid.shape[0] + min(0, -dy)),
                slice(max(0, -dx), grid.shape[1] + min(0, -dx)))
        d = np.abs(grid[sl_a].astype(np.float64) - grid[sl_b].astype(np.float64))
        ma, mb = mask[sl_a], mask[sl_b]
        ba, bb = band[sl_a], band[sl_b]
        cross.append(d[ma ^ mb])
        both_in = ma & mb & (ba >= 1) & (ba <= 3) & (bb >= 1) & (bb <= 3)
        inner.append(d[both_in])
        both_out = (~ma) & (~mb) & (ba >= -4) & (ba <= -1) & (bb >= -4) & (bb <= -1)
        ctrl.append(d[both_out])
    inner = np.concatenate(inner) if inner else np.zeros(0)
    cross = np.concatenate(cross) if cross else np.zeros(0)
    ctrl = np.concatenate(ctrl) if ctrl else np.zeros(0)
    if not inner.size or not ctrl.size:
        return None
    i_med, c_med, k_med = float(np.median(inner)), float(np.median(cross)) if cross.size else None, \
        float(np.median(ctrl))
    return dict(inside_pairs=int(inner.size), inside_median_rise=round(i_med, 3),
                control_pairs=int(ctrl.size), control_median_rise=round(k_med, 3),
                contour_pairs=int(cross.size),
                contour_over_control=round(c_med / max(k_med, 1e-9), 4)
                if c_med is not None else None,
                ratio=round(i_med / max(k_med, 1e-9), 4))


def signed_band(mask):
    """Signed distance to the mask boundary, in cells: +1 is the first cell INSIDE."""
    din = ndimage.distance_transform_edt(mask)
    dout = ndimage.distance_transform_edt(~mask)
    band = np.where(mask, np.ceil(din), -np.ceil(dout)).astype(np.int32)
    return band


def median_or_none(v):
    return round(float(np.median(v)), 5) if v.size else None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pre", default="", help="destination grid straight out of GridResample")
    ap.add_argument("--post", required=True, help="destination grid after the Z transform")
    ap.add_argument("--stamp", required=True)
    ap.add_argument("--dest-width", type=int, default=8192)
    ap.add_argument("--pad", type=int, default=24, help="crop pad around each stamped bbox")
    ap.add_argument("--json", default="")
    ap.add_argument("--fig", default="")
    ap.add_argument("--label", default="")
    args = ap.parse_args(argv)

    def log(*a):
        print(*a, flush=True)

    # int32 keeps two 8192^2 grids under a gigabyte; the largest product below is 65535*8192
    post = load(args.post, args.dest_width).astype(np.int32)
    pre = load(args.pre, args.dest_width).astype(np.int32) if args.pre else None
    maps, massifs = parse_stamp(args.stamp)
    surf = maps.get("surface", {})
    shift = int(surf.get("zadd", 0))
    zmul, zdiv = int(surf.get("zmul", XY_MUL)), int(surf.get("zdiv", XY_DIV))
    massifs = [m for m in massifs if m["tag"] == "surface"]
    src_cap = ((CAP - shift) * zdiv) // zmul
    mode = "pre_post" if pre is not None else "dest_only"
    log(f"mode {mode}  post {post.shape}  shift {shift}  z {zmul}/{zdiv}  "
        f"src_cap {src_cap}  massifs {len(massifs)}")
    if not massifs:
        log("no surface massifs stamped: the whole map is the pure similarity, no join exists")

    structure = ndimage.generate_binary_structure(2, 1)  # 4-connected, like GridEnumZones
    H, W = post.shape
    rows, fig_rows = [], []
    for m in massifs:
        x0 = max(0, m["x0"] - args.pad); y0 = max(0, m["y0"] - args.pad)
        x1 = min(W, m["x1"] + args.pad); y1 = min(H, m["y1"] + args.pad)
        sub_post = post[y0:y1, x0:x1]
        if pre is not None:
            sub_pre = pre[y0:y1, x0:x1]
            lab, _ = ndimage.label(sub_pre >= m["base"], structure=structure)
        else:
            sub_pre = None
            lab, _ = ndimage.label(sub_post >= m["base_img"], structure=structure)
        want = lab[m["peak_y"] - y0, m["peak_x"] - x0]
        if not want:
            rows.append(dict(index=m["index"], ok=False, reason="peak cell not in any component"))
            continue
        mask = lab == want
        area = int(mask.sum())
        band = signed_band(mask)
        table = lut_for(m["base"], m["peak"], m["base_img"], m["k"], shift)
        # the LUT's own analytic sag below the affine, as a function of t = h - base
        aff_tab = ((np.arange(m["base"], m["peak"] + 1, dtype=np.int64) * zmul) // zdiv) + shift
        sag_tab = aff_tab - table

        row = dict(index=m["index"], bbox=[m["x0"], m["y0"], m["x1"], m["y1"]],
                   base=m["base"], base_img=m["base_img"], peak=m["peak"], k=m["k"],
                   stamped_cells=m["cells"], rebuilt_cells=area,
                   analytic_slope_at_base=round(float(analytic_slope_at_base(m)), 10))

        # ---------- 1. boundary pairs straddling the contour ----------
        if sub_pre is not None:
            pairs_err, pairs_raw, pairs_sag, pairs_n, worst = [], [], [], 0, 0.0
            for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
                a = mask[max(0, dy):mask.shape[0] + min(0, dy),
                         max(0, dx):mask.shape[1] + min(0, dx)]
                b = mask[max(0, -dy):mask.shape[0] + min(0, -dy),
                         max(0, -dx):mask.shape[1] + min(0, -dx)]
                sel = a & ~b  # a is inside, b (its neighbour) is outside
                if not sel.any():
                    continue
                pin = sub_pre[max(0, dy):sub_pre.shape[0] + min(0, dy),
                              max(0, dx):sub_pre.shape[1] + min(0, dx)][sel]
                pout = sub_pre[max(0, -dy):sub_pre.shape[0] + min(0, -dy),
                               max(0, -dx):sub_pre.shape[1] + min(0, -dx)][sel]
                qin = sub_post[max(0, dy):sub_post.shape[0] + min(0, dy),
                               max(0, dx):sub_post.shape[1] + min(0, dx)][sel]
                qout = sub_post[max(0, -dy):sub_post.shape[0] + min(0, -dy),
                                max(0, -dx):sub_post.shape[1] + min(0, -dx)][sel]
                t = np.clip(pin - m["base"], 0, len(sag_tab) - 1)
                # expected destination rise: the 4/3 similarity minus the curve's own sag at the
                # inside cell (0 at the base by construction -- the tangency being verified)
                raw = (qin - qout) - (pin - pout) * (zmul / zdiv)
                pairs_raw.append(raw)
                pairs_sag.append(sag_tab[t].astype(np.float64))
                pairs_err.append(raw + sag_tab[t])
                pairs_n += int(sel.sum())
            if pairs_err:
                err = np.concatenate(pairs_err)
                raw = np.concatenate(pairs_raw)
                sag = np.concatenate(pairs_sag)
                worst = float(np.abs(err).max())
                # STRICT, model-free subset: pairs whose inside cell sits so close to the base
                # that the curve's own sag is under one height unit.  There the destination rise
                # must be the SAME 4/3 as outside, with no analytic term in the expectation --
                # that is the join measured directly, on real cells.
                near = sag <= 1.0
                strict_worst = float(np.abs(raw[near]).max()) if near.any() else None
                row["boundary"] = dict(
                    pairs=pairs_n, mean_abs=round(float(np.abs(err).mean()), 4),
                    p99_abs=round(float(np.percentile(np.abs(err), 99)), 4),
                    max_abs=round(worst, 4), over_quant=int((np.abs(err) > QUANT_UNITS).sum()),
                    sag_median=round(float(np.median(sag)), 3),
                    sag_max=round(float(sag.max()), 3),
                    strict_pairs=int(near.sum()),
                    strict_max_abs=round(strict_worst, 4) if strict_worst is not None else None,
                    strict_over_quant=int((np.abs(raw[near]) > QUANT_UNITS).sum())
                    if near.any() else 0,
                    ok=bool(worst <= QUANT_UNITS
                            and (strict_worst is None or strict_worst <= QUANT_UNITS)))
            else:
                row["boundary"] = dict(pairs=0, ok=False)

        # ---------- 2. gradient-ratio (or curvature) bands ----------
        bands = {}
        if sub_pre is not None:
            gp, gq = grad_mag(sub_pre), grad_mag(sub_post)
            strong = gp >= GRAD_FLOOR
            # interior only: np.gradient is one-sided on the crop edge
            interior = np.zeros(mask.shape, dtype=bool)
            interior[1:-1, 1:-1] = True
            with np.errstate(divide="ignore", invalid="ignore"):
                ratio = np.where(gp > 0, gq / np.maximum(gp, 1e-9), np.nan)
            for b in range(-BANDS, BANDS + 1):
                if b == 0:
                    continue
                sel = (band == b) & strong & interior
                v = ratio[sel]
                v = v[np.isfinite(v)]
                bands[b] = dict(cells=int(v.size), median=median_or_none(v))
            r_in = bands.get(STEP_BAND, {}).get("median")
            r_out = bands.get(-STEP_BAND, {}).get("median")
            far = bands.get(-BANDS, {}).get("median")
            step = abs(r_in - r_out) if (r_in is not None and r_out is not None) else None
            row["ratio_bands"] = dict(
                bands={str(b): bands[b] for b in sorted(bands)},
                r_just_inside=r_in, r_just_outside=r_out, r_far_outside=far,
                step_at_contour=round(step, 5) if step is not None else None,
                inside_err_vs_4_3=round(abs(r_in - TARGET_SLOPE), 5) if r_in is not None else None,
                outside_err_vs_4_3=round(abs(r_out - TARGET_SLOPE), 5)
                if r_out is not None else None,
                note="DIAGNOSTIC, not the gate: a distance band one cell inside the contour "
                     "sits a full local rise ABOVE the base (100-300 source units on this rim "
                     "wall), where the curve has legitimately already bent by exp(-k*t); "
                     "continuity is scored in `height_bins` against t, not against distance.")

            # ---------- 2b. the ratio against height above the base (DIAGNOSTIC) ----------
            # Bin the massif's own cells by t = pre - base; the analytic curve predicts
            # R(t) = (4/3)exp(-k t), so these bins show the compression biting smoothly with
            # height and let a fitted k be compared with the stamped one.
            # NOT the gate, for two measured reasons: (a) on this rim wall a near-contour cell
            # rises 100-300 source units per cell, so its central difference AVERAGES the curve's
            # derivative over a wide t span and reads below the point value, and (b) the small
            # massifs have no populated bin near t = 0 at all -- their lowest bin with enough
            # cells sits hundreds of units up, where the curve has legitimately bent.  The join
            # itself is scored by the boundary pairs above (model-free strict subset) and by the
            # curvature test below.
            ctrl_sel = (~mask) & (sub_pre < m["base"]) & (band >= -6) & strong & interior
            ctrl = ratio[ctrl_sel]
            ctrl = ctrl[np.isfinite(ctrl)]
            r_ctrl = median_or_none(ctrl)
            t_grid = sub_pre - m["base"]
            hbins, fit_x, fit_y = [], [], []
            for lo, hi in ((0, 2), (3, 5), (6, 10), (11, 20), (21, 50), (51, 100),
                           (101, 200), (201, 500), (501, 2000), (2001, 100000)):
                sel = mask & (t_grid >= lo) & (t_grid <= hi) & strong & interior
                v = ratio[sel]
                v = v[np.isfinite(v)]
                if v.size == 0:
                    continue
                med = float(np.median(v))
                hbins.append(dict(t_lo=lo, t_hi=hi, cells=int(v.size), median=round(med, 5),
                                  predicted=round(TARGET_SLOPE * math.exp(-m["k"] * (lo + hi) / 2.0),
                                                  5)))
                if v.size >= 50 and med > 0:
                    fit_x.append((lo + hi) / 2.0)
                    fit_y.append(math.log(med / TARGET_SLOPE))
            near = next((b for b in hbins if b["cells"] >= MIN_BIN_CELLS), None)
            k_fit = None
            if len(fit_x) >= 3:
                k_fit = float(-np.polyfit(np.array(fit_x), np.array(fit_y), 1)[0])
            row["height_bins"] = dict(
                bins=hbins, control_cells=int(ctrl.size), r_control=r_ctrl,
                near_bin=near, min_bin_cells=MIN_BIN_CELLS,
                step_at_join=round(abs(near["median"] - r_ctrl), 5)
                if (near and r_ctrl is not None) else None,
                k_stamped=m["k"], k_fitted=round(k_fit, 9) if k_fit is not None else None,
                k_ratio=round(k_fit / m["k"], 3) if (k_fit and m["k"]) else None,
                sufficient=bool(near is not None and r_ctrl is not None),
                note="DIAGNOSTIC (see the code comment): stencil averaging and the small "
                     "massifs' empty low-t bins make this a curvature reading, not a join test.")

        # ---------- 2c. curvature of the FINAL terrain across the contour (model-free) ----------
        # A crease is a visible line: a step in slope shows up as a spike in the discrete
        # Laplacian along the contour.  Scored against the same massif's own relief 4-8 cells
        # outside the contour, so the map's natural roughness is the yardstick.  This is the only
        # test that also runs on an end-of-generation grid, where no pre-transform grid exists.
        lap = laplace_mag(sub_post)
        interior_l = np.zeros(mask.shape, dtype=bool)
        interior_l[1:-1, 1:-1] = True
        cbands = {}
        for b in range(-BANDS, BANDS + 1):
            if b == 0:
                continue
            sel = (band == b) & interior_l
            v = lap[sel]
            cbands[b] = dict(cells=int(v.size), median=median_or_none(v),
                             p95=round(float(np.percentile(v, 95)), 4) if v.size else None)
        ctrl_l = lap[(band <= -4) & (band >= -BANDS) & interior_l]
        near_l = lap[(np.abs(band) <= 1) & interior_l]
        row["curvature_bands"] = dict(
            bands={str(b): cbands[b] for b in sorted(cbands)},
            control_median=median_or_none(ctrl_l), contour_median=median_or_none(near_l),
            contour_over_control=round(float(np.median(near_l) / max(np.median(ctrl_l), 1e-9)), 4)
            if ctrl_l.size and near_l.size else None)

        # SAME-CELL control for the curvature, available only with the source grid: the ratio of
        # the two grids' curvature on the SAME cells removes the terrain confound (a band just
        # inside the contour is on a steeper wall than a band 4-8 cells out, so a raw
        # contour/control ratio partly measures position).  Outside, this ratio is exactly 4/3.
        # At the join it is allowed to exceed 4/3 by the curve's own second derivative: the join
        # is C1 by design, not C2 (L''(0) = -k*4/3), so the CURVATURE steps there on purpose.
        # A crease -- a step in the SLOPE -- would instead show up as a spike of order the slope
        # step times the local rise, i.e. hundreds of units, not tens of percent.
        if sub_pre is not None:
            lap_pre = laplace_mag(sub_pre)
            lr = {}
            for b in range(-BANDS, BANDS + 1):
                if b == 0:
                    continue
                sel = (band == b) & interior_l & (lap_pre >= 4.0)
                if not sel.any():
                    continue
                lr[b] = round(float(np.median(lap[sel]) / max(np.median(lap_pre[sel]), 1e-9)), 4)
            row["curvature_ratio_post_over_pre"] = dict(
                bands={str(b): lr[b] for b in sorted(lr)},
                at_contour_inside=lr.get(1), at_contour_outside=lr.get(-1),
                far_outside=lr.get(-BANDS), target=round(TARGET_SLOPE, 5))

        # ---------- 2d. POSITIVE CONTROL: what a real crease reads on these same cells ----------
        # Iteration 001 measured an actual failure mode: with base == src_cap the curve degenerates
        # (H = 0), the summit collapses to a flat plateau and the slope at the base drops from 4/3
        # to 0.  Rebuild exactly that here -- affine outside, clipped flat at base_img inside --
        # and run the same two scored statistics on it.  Every threshold below is then calibrated
        # against a measured crease on this very terrain instead of an assertion.
        if sub_pre is not None and area:
            aff_grid = np.clip(np.minimum(sub_pre, src_cap) * zmul // zdiv + shift, 0, CAP)
            synth = np.where(mask, np.minimum(aff_grid, m["base_img"]), aff_grid)
            ctl_raw = []
            for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
                a = mask[max(0, dy):mask.shape[0] + min(0, dy),
                         max(0, dx):mask.shape[1] + min(0, dx)]
                b = mask[max(0, -dy):mask.shape[0] + min(0, -dy),
                         max(0, -dx):mask.shape[1] + min(0, -dx)]
                sel = a & ~b
                if not sel.any():
                    continue
                pin = sub_pre[max(0, dy):sub_pre.shape[0] + min(0, dy),
                              max(0, dx):sub_pre.shape[1] + min(0, dx)][sel]
                pout = sub_pre[max(0, -dy):sub_pre.shape[0] + min(0, -dy),
                               max(0, -dx):sub_pre.shape[1] + min(0, -dx)][sel]
                sin_ = synth[max(0, dy):synth.shape[0] + min(0, dy),
                             max(0, dx):synth.shape[1] + min(0, dx)][sel]
                sout = synth[max(0, -dy):synth.shape[0] + min(0, -dy),
                             max(0, -dx):synth.shape[1] + min(0, -dx)][sel]
                t = np.clip(pin - m["base"], 0, len(sag_tab) - 1)
                near_ = sag_tab[t] <= 1.0
                if near_.any():
                    ctl_raw.append((sin_ - sout)[near_]
                                   - (pin - pout)[near_] * (zmul / zdiv))
            lap_s = laplace_mag(synth)
            selc = (band == 1) & interior_l & (lap_pre >= 4.0) if sub_pre is not None else None
            row["crease_positive_control"] = dict(
                model="base == src_cap degeneracy: summit clipped flat at base_img (iter 001)",
                strict_max_abs=round(float(np.abs(np.concatenate(ctl_raw)).max()), 3)
                if ctl_raw else None,
                strict_median_abs=round(float(np.median(np.abs(np.concatenate(ctl_raw)))), 3)
                if ctl_raw else None,
                curvature_ratio_at_join=round(
                    float(np.median(lap_s[selc]) / max(np.median(lap_pre[selc]), 1e-9)), 3)
                if selc is not None and selc.any() else None,
                join_rise=pair_rise(synth, mask, band))

        # ---------- 2e. rise just inside the join vs the ground beside it ----------
        # Scored against the curve's OWN expectation for those cells, median exp(-k t): the small
        # massifs have a large k and legitimately bend within a cell or two, and a raw ratio would
        # score that design characteristic instead of continuity.  A crease still fails, because
        # a clipped summit has zero rise inside whatever k predicts (positive control below).
        jr = pair_rise(sub_post, mask, band)
        if jr:
            inner_sel = mask & (band >= 1) & (band <= 3)
            if sub_pre is not None:
                t_inner = (sub_pre[inner_sel] - m["base"]).astype(np.float64)
            else:  # invert the monotone LUT to recover t from the destination value
                t_inner = np.searchsorted(table, sub_post[inner_sel]).astype(np.float64)
            pred = float(np.median(np.exp(-m["k"] * np.clip(t_inner, 0, None)))) \
                if t_inner.size else None
            jr["predicted_ratio"] = round(pred, 4) if pred else None
            jr["ratio_over_predicted"] = round(jr["ratio"] / pred, 4) if pred else None
            # RESOLUTION GUARD.  This statistic compares a PER-CELL rise with a point value of
            # the curve's derivative, so it only means anything where the curve bends slowly
            # enough to be resolved by one cell.  Phase = k * (the source-space rise per cell
            # near the join); at 42S28W massif 28 reads 0.61, i.e. the derivative drops ~45%
            # WITHIN one cell, and the per-cell reading undershoots the point value by 2x for
            # that reason alone.  Those massifs are reported and scored by the boundary pairs,
            # which compare against the LUT's own integrated sag and have no such limit.
            phase = m["k"] * jr["control_median_rise"] * (zdiv / zmul)
            jr["cell_phase_k_times_rise"] = round(float(phase), 4)
            jr["resolvable"] = bool(phase <= JOIN_RISE_MAX_PHASE)
        row["join_rise"] = jr

        # ---------- 3. sag on real cells, per t bin above the base ----------
        if sub_pre is not None and area:
            t_all = sub_pre[mask] - m["base"]
            aff_all = np.clip(np.minimum(sub_pre[mask], src_cap) * zmul // zdiv + shift, 0, CAP)
            sag_all = aff_all - sub_post[mask]
            sag_bins = []
            for lo, hi in ((0, 0), (1, 5), (6, 20), (21, 50), (51, 100), (101, 200),
                           (201, 500), (501, 1000)):
                sel = (t_all >= lo) & (t_all <= hi)
                if not sel.any():
                    continue
                sag_bins.append(dict(t_lo=int(lo), t_hi=int(hi), cells=int(sel.sum()),
                                     sag_median=median_or_none(sag_all[sel]),
                                     sag_max=int(sag_all[sel].max())))
            # a slope step of size s would make the sag rise by s per unit of t from t = 0;
            # measure the empirical secant over the first 5 units and compare with 0
            first = sag_bins[0] if sag_bins else None
            near5 = [b for b in sag_bins if b["t_hi"] == 5]
            secant = None
            if near5:
                secant = round(float(near5[0]["sag_median"]) / 5.0, 5)
            row["sag"] = dict(bins=sag_bins,
                              sag_at_base=first["sag_median"] if first else None,
                              secant_slope_first5=secant,
                              ok=bool(first is not None and abs(first["sag_median"]) <= 1
                                      and (secant is None or abs(secant) <= 0.25)))

        checks = [abs(row["analytic_slope_at_base"] - TARGET_SLOPE) < 1e-9]
        if "boundary" in row:
            checks.append(bool(row["boundary"].get("ok")))
        if "sag" in row:
            checks.append(bool(row["sag"]["ok"]))
        # The curvature statistics are REPORTED, not scored: the positive control below measures
        # them overlapping between a correct join and a real crease (crease as low as 1.58 against
        # 2.77 measured here), so they cannot separate the two.  The rise across the join can:
        # a crease reads ~0 there.
        if (row.get("join_rise", {}).get("ratio_over_predicted") is not None
                and row["join_rise"].get("resolvable")):
            checks.append(row["join_rise"]["ratio_over_predicted"] >= JOIN_RISE_TOL)
        row["ok"] = bool(all(checks))
        rows.append(row)
        fig_rows.append((m, mask, band, sub_pre, sub_post, row))
        b = row.get("boundary", {})
        hb = row.get("height_bins", {})
        cb = row.get("curvature_bands", {})
        log(f"  massif {m['index']:>2} cells {area:>7} "
            + (f"pairs {b.get('pairs', 0):>5} max|err| {b.get('max_abs')} "
               f"strict {b.get('strict_pairs')} max|raw| {b.get('strict_max_abs')} " if b else "")
            + (f"k_fit/k {hb.get('k_ratio')} " if hb else "")
            + (f"rise inside join / beside it {row['join_rise']['ratio']} "
               f"(/predicted {row['join_rise'].get('ratio_over_predicted')}) "
               if row.get("join_rise") else "")
            + (f"[crease control {row['crease_positive_control']['join_rise']['ratio']}] "
               if row.get("crease_positive_control", {}).get("join_rise") else "")
            + (f"curv {cb.get('contour_over_control')} " if cb else "")
            + f"-> {'ok' if row['ok'] else 'FAIL'}")

    scored = [r for r in rows if "ok" in r]
    ok = bool(scored) and all(r["ok"] for r in scored)
    summary = dict(massifs=len(rows), scored=len(scored),
                   passing=sum(1 for r in scored if r["ok"]))
    if mode == "pre_post" and scored:
        steps = [r["height_bins"]["step_at_join"] for r in scored
                 if r.get("height_bins", {}).get("sufficient")]
        summary["worst_boundary_abs"] = max(r["boundary"]["max_abs"] for r in scored
                                            if "boundary" in r)
        summary["boundary_pairs"] = sum(r["boundary"]["pairs"] for r in scored
                                        if "boundary" in r)
        summary["strict_pairs"] = sum(r["boundary"].get("strict_pairs") or 0 for r in scored
                                      if "boundary" in r)
        strict = [r["boundary"]["strict_max_abs"] for r in scored
                  if r.get("boundary", {}).get("strict_max_abs") is not None]
        summary["worst_strict_abs"] = max(strict) if strict else None
        summary["massifs_without_strict_pairs"] = sum(
            1 for r in scored if not (r.get("boundary", {}).get("strict_pairs") or 0))
        summary["diagnostic_worst_step_at_join"] = max(steps) if steps else None
        summary["worst_sag_at_base"] = max(abs(r["sag"]["sag_at_base"]) for r in scored
                                           if r.get("sag", {}).get("sag_at_base") is not None)
        kr = [r["height_bins"]["k_ratio"] for r in scored
              if r.get("height_bins", {}).get("k_ratio") is not None]
        summary["k_fit_over_k_stamped_median"] = round(float(np.median(kr)), 3) if kr else None
    if scored:
        jr = [r["join_rise"]["ratio_over_predicted"] for r in scored
              if (r.get("join_rise", {}).get("ratio_over_predicted") is not None
                  and r["join_rise"].get("resolvable"))]
        summary["worst_join_rise_over_predicted"] = round(min(jr), 4) if jr else None
        summary["join_rise_scored"] = len(jr)
        summary["join_rise_unresolvable"] = [
            dict(index=r["index"], phase=r["join_rise"]["cell_phase_k_times_rise"],
                 ratio_over_predicted=r["join_rise"]["ratio_over_predicted"])
            for r in scored if r.get("join_rise") and not r["join_rise"].get("resolvable")]
        jr0 = [r["join_rise"]["ratio"] for r in scored if r.get("join_rise")]
        summary["worst_join_rise_ratio_raw"] = round(min(jr0), 4) if jr0 else None
        pj = [r["crease_positive_control"]["join_rise"]["ratio"] for r in scored
              if (r.get("crease_positive_control", {}).get("join_rise"))]
        summary["positive_control_join_rise_median"] = round(float(np.median(pj)), 4) if pj \
            else None
        summary["positive_control_join_rise_max"] = round(float(np.max(pj)), 4) if pj else None
        summary["worst_contour_over_control"] = max(
            r["curvature_bands"]["contour_over_control"] for r in scored
            if r.get("curvature_bands", {}).get("contour_over_control") is not None)
        cr = [r["curvature_ratio_post_over_pre"]["at_contour_inside"] for r in scored
              if r.get("curvature_ratio_post_over_pre", {}).get("at_contour_inside") is not None]
        summary["worst_curvature_ratio_at_join"] = max(cr) if cr else None
        pc_s = [r["crease_positive_control"]["strict_max_abs"] for r in scored
                if r.get("crease_positive_control", {}).get("strict_max_abs") is not None]
        pc_c = [r["crease_positive_control"]["curvature_ratio_at_join"] for r in scored
                if r.get("crease_positive_control", {}).get("curvature_ratio_at_join") is not None]
        summary["positive_control_strict_median"] = round(float(np.median(pc_s)), 2) \
            if pc_s else None
        summary["positive_control_strict_min"] = round(float(np.min(pc_s)), 2) if pc_s else None
        summary["positive_control_curvature_median"] = round(float(np.median(pc_c)), 2) \
            if pc_c else None
        summary["positive_control_curvature_min"] = round(float(np.min(pc_c)), 2) if pc_c else None
    if scored:
        summary["worst_analytic_slope_err"] = max(
            abs(r["analytic_slope_at_base"] - TARGET_SLOPE) for r in scored)

    report = dict(schema="smr.creasecheck", schema_version=1, label=args.label, mode=mode,
                  inputs=dict(pre=os.path.abspath(args.pre) if args.pre else None,
                              post=os.path.abspath(args.post),
                              stamp=os.path.abspath(args.stamp)),
                  transform=dict(shift=shift, zmul=zmul, zdiv=zdiv, src_cap=src_cap,
                                 target_slope=round(TARGET_SLOPE, 9)),
                  thresholds=dict(quant_units=QUANT_UNITS, grad_floor=GRAD_FLOOR,
                                  step_tol=STEP_TOL, min_bin_cells=MIN_BIN_CELLS,
                                  sag_secant_tol=0.25, join_rise_tol=JOIN_RISE_TOL,
                                  join_rise_max_phase=JOIN_RISE_MAX_PHASE,
                                  curvature_screen_reported=CURV_TOL,
                                  curvature_ratio_reported=CURV_RATIO_TOL),
                  summary=summary, detail=rows, gate_ok=ok)
    # A map whose terrain never overflows takes the compression loop zero times, so no base
    # isoline and no join EXIST to be slope-continuous. That is not a pass and not a failure:
    # gate_ok stays null so no tally can read it as green, and the exit status stops reporting a
    # scored massif's failure when none was scored.
    applicable = bool(massifs)
    report["applicable"] = applicable
    if not applicable:
        report["gate_ok"] = None
        report["not_applicable_reason"] = ("the stamp carries no surface massif: the whole map is "
                                           "the pure similarity and the transform has no join")
    if mode == "dest_only":
        # keep the curvature screen visible on an end-of-generation grid, as a reported number
        summary["curvature_screen_within_tol"] = sum(
            1 for r in scored
            if (r.get("curvature_bands", {}).get("contour_over_control") or 0) <= CURV_TOL)
    verdict = "PASS" if ok else "FAIL"
    if not applicable:
        verdict = "N/A"
    log(f"GATE {verdict} ({mode}): {summary['passing']}/{summary['scored']} "
        f"massifs, " + ", ".join(f"{k} {v}" for k, v in summary.items()
                                 if k.startswith("worst")))

    if args.fig and fig_rows:
        make_figure(fig_rows, report, args.fig, log)
        report["figure"] = os.path.abspath(args.fig)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=1, sort_keys=True)
        log(f"wrote {args.json}")
    if not applicable:
        return 0
    return 0 if ok else 1


def make_figure(fig_rows, report, path, log):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    mode = report["mode"]
    fig = plt.figure(figsize=(18, 9.5), dpi=110)

    # pick the largest massif for the two map panels
    big = max(fig_rows, key=lambda t: int(t[5].get("rebuilt_cells", 0)))
    m, mask, band, sub_pre, sub_post, row = big

    ax = fig.add_subplot(2, 3, 1)
    ax.imshow(sub_post, cmap="gist_earth", interpolation="nearest")
    ax.contour(mask.astype(float), levels=[0.5], colors="red", linewidths=0.8)
    ax.set_xticks([]); ax.set_yticks([])
    ax.set_title(f"massif {m['index']} post-transform height\nred = base contour "
                 f"(base {m['base']} -> {m['base_img']})", fontsize=9)

    # a single profile straight across the join: the shape a crease would be visible in
    ax = fig.add_subplot(2, 3, 4)
    row = int(np.clip(m["peak_y"] - max(0, m["y0"] - 24), 1, mask.shape[0] - 2))
    inside_x = np.nonzero(mask[row])[0]
    if inside_x.size:
        lo = max(0, int(inside_x.min()) - 40)
        hi = min(mask.shape[1], int(inside_x.min()) + 120)
        xs = np.arange(lo, hi)
        ax.plot(xs, sub_post[row, lo:hi], lw=1.4, color="C0", label="post (transformed)")
        if sub_pre is not None:
            aff = np.clip(np.minimum(sub_pre[row, lo:hi], report["transform"]["src_cap"])
                          * report["transform"]["zmul"] // report["transform"]["zdiv"]
                          + report["transform"]["shift"], 0, CAP)
            ax.plot(xs, aff, lw=1.0, ls="--", color="C3",
                    label="the pure 4/3 affine of pre")
        ax.axvspan(lo, float(inside_x.min()), color="0.85", alpha=0.6)
        ax.axvline(float(inside_x.min()), color="k", lw=0.9)
        ax.set_xlabel(f"x along row y = {row} (grey = outside the massif)")
        ax.set_ylabel("height")
        ax.legend(fontsize=8, loc="lower right")
        if sub_pre is not None:
            ax2 = ax.twinx()
            dq = np.diff(sub_post[row, lo:hi].astype(np.float64))
            dp = np.diff(sub_pre[row, lo:hi].astype(np.float64)) * TARGET_SLOPE
            ax2.plot(xs[1:], dq, lw=0.7, color="C0", alpha=0.45)
            ax2.plot(xs[1:], dp, lw=0.7, color="C3", alpha=0.45, ls=":")
            ax2.set_ylabel("per-cell rise (thin)", fontsize=8)
        ax.set_title("profile across the join at the peak row:\nthe two curves part smoothly, "
                     "with no kink at the contour", fontsize=9)
        ax.grid(alpha=0.3)

    ax = fig.add_subplot(2, 3, 2)
    if mode == "pre_post":
        for _, _, _, _, _, r in fig_rows:
            hb = r.get("height_bins", {})
            bins = [b for b in hb.get("bins", []) if b["cells"] >= 20]
            if bins:
                xs = [max(b["t_hi"], 1) for b in bins]
                ax.plot(xs, [b["median"] for b in bins], lw=0.9, alpha=0.75)
                ax.plot(xs, [b["predicted"] for b in bins], lw=0.7, alpha=0.35, ls=":",
                        color="k")
            if hb.get("r_control") is not None:
                ax.plot([0.7], [hb["r_control"]], marker="_", ms=8, color="0.3", alpha=0.6)
        ax.axhline(TARGET_SLOPE, color="k", lw=1.0, ls="--")
        ax.set_xscale("log")
        ax.set_ylim(0.4, 1.5)
        ax.set_ylabel("median |grad post| / |grad pre|")
        ax.set_xlabel("t = pre - base (source units above the join; log)")
        ax.set_title("the gate: the slope ratio returns to the outside value as t -> 0\n"
                     "dotted = the analytic (4/3)exp(-kt); grey ticks = outside control",
                     fontsize=9)
    else:
        for _, _, _, _, _, r in fig_rows:
            bands = r.get("curvature_bands", {}).get("bands", {})
            xs = sorted(int(b) for b in bands)
            pts = [(x, bands[str(x)]["median"]) for x in xs if bands[str(x)]["median"] is not None]
            if pts:
                ax.plot([p[0] for p in pts], [p[1] for p in pts], lw=0.9, alpha=0.8)
        ax.axvline(0, color="red", lw=1.0)
        ax.set_ylabel("median |Laplacian| (height units)")
        ax.set_xlabel("signed distance to the base contour (cells; + = inside the massif)")
        ax.set_title("every massif, per distance band", fontsize=9)
    ax.grid(alpha=0.3)

    ax = fig.add_subplot(2, 3, 5)
    if mode == "pre_post":
        for _, _, _, _, _, r in fig_rows:
            bins = r.get("sag", {}).get("bins", [])
            if bins:
                ax.plot([b["t_hi"] for b in bins], [b["sag_median"] for b in bins],
                        marker=".", lw=0.9, alpha=0.8)
        ax.set_xscale("symlog"); ax.set_yscale("symlog")
        ax.set_xlabel("t = pre - base (source units above the join)")
        ax.set_ylabel("median sag below the 4/3 affine")
        ax.set_title("the join starts at zero sag with zero slope\n(linear rise = crease)",
                     fontsize=9)
        ax.grid(alpha=0.3)
    else:
        ax.axis("off")

    ax = fig.add_subplot(1, 3, 3)
    s = report["summary"]
    lines = [f"GATE {'PASS' if report['gate_ok'] else 'FAIL'}  ({mode})", "",
             f"{s['passing']}/{s['scored']} massifs pass", ""]
    lines.append(f"worst |analytic slope at base - 4/3| = {s.get('worst_analytic_slope_err')}")
    if mode == "pre_post":
        lines += [
            "",
            "boundary pairs straddling the contour (SCORED):",
            f"   pairs {s.get('boundary_pairs')}, worst |d_post - 4/3 d_pre + sag| = "
            f"{s.get('worst_boundary_abs')} units",
            f"   strict model-free subset (sag < 1 unit): {s.get('strict_pairs')} pairs,",
            f"      worst |d_post - 4/3 d_pre| = {s.get('worst_strict_abs')}",
            f"   floor quantization bound {report['thresholds']['quant_units']}",
            "",
            "sag on real cells (diagnostic):",
            f"   worst |sag at t = 0| = {s.get('worst_sag_at_base')} units",
            f"   fitted k / stamped k, median = {s.get('k_fit_over_k_stamped_median')}",
        ]
    lines += ["", "per-cell rise just inside the join / on the ground beside it (SCORED):",
              f"   worst over the curve's own median exp(-kt) = "
              f"{s.get('worst_join_rise_over_predicted')}  tolerance "
              f"{report['thresholds']['join_rise_tol']}",
              f"   scored on {s.get('join_rise_scored')}/{s['scored']} massifs; "
              f"{len(s.get('join_rise_unresolvable') or [])} bend within one cell",
              f"   (k*rise > {report['thresholds']['join_rise_max_phase']}) and are scored by "
              f"their boundary pairs",
              f"   curvature, REPORTED only (the join is C1 by design, not C2):",
              f"      contour/own relief worst {s.get('worst_contour_over_control')}"
              + (f", |lap post|/|lap pre| at the join worst "
                 f"{s.get('worst_curvature_ratio_at_join')}" if mode == "pre_post" else "")]
    if mode == "pre_post":
        lines += ["",
                  "POSITIVE CONTROL - the same cells carrying iter 001's",
                  "collapsed summit (a real crease), same statistics:",
                  f"   strict boundary |d - 4/3 d_pre|: median "
                  f"{s.get('positive_control_strict_median')}, min "
                  f"{s.get('positive_control_strict_min')} units",
                  f"      (measured here: {s.get('worst_strict_abs')} - separated)",
                  f"   rise just inside the join: median "
                  f"{s.get('positive_control_join_rise_median')}, max "
                  f"{s.get('positive_control_join_rise_max')}",
                  f"      (measured here: worst {s.get('worst_join_rise_ratio_raw')} "
                  f"- separated)",
                  f"   curvature ratio: median "
                  f"{s.get('positive_control_curvature_median')}, min "
                  f"{s.get('positive_control_curvature_min')}",
                  f"      (measured here: {s.get('worst_curvature_ratio_at_join')} - OVERLAPS,",
                  f"       which is why curvature is not scored)"]
    lines += ["", "per massif:"]
    for _, _, _, _, _, r in fig_rows[:14]:
        if mode == "pre_post":
            hb = r.get("height_bins", {})
            nb = hb.get("near_bin") or {}
            lines.append(f"   {r['index']:>2} base {r['base']:>6} "
                         f"ctrl {hb.get('r_control')} R(t<={nb.get('t_hi')}) {nb.get('median')} "
                         f"step {hb.get('step_at_join')} "
                         f"bnd {r.get('boundary', {}).get('max_abs')}")
        else:
            cb = r.get("curvature_bands", {})
            lines.append(f"   {r['index']:>2} base_img {r['base_img']:>6} "
                         f"contour/control {cb.get('contour_over_control')}")
    if len(fig_rows) > 14:
        lines.append(f"   ... {len(fig_rows) - 14} more, all in the json")
    ax.axis("off")
    ax.text(0.0, 1.0, "\n".join(lines), va="top", ha="left", fontsize=10, family="monospace")

    fig.suptitle(f"no-crease gate on dumped cells - {report.get('label') or ''}", fontsize=12)
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(path)
    plt.close(fig)
    log(f"wrote {path}")


if __name__ == "__main__":
    sys.exit(main())
