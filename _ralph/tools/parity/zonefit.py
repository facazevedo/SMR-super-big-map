"""Offline reference for the full-4/3 Z transform with per-mountain ceiling normalization.

This is the authoritative, inspectable implementation of the algorithm the mod must
reproduce in Lua (`sbm_terrain_copy.lua`'s `stretch_one`), plus the numeric verification of
its gates.  It runs on a raw U16 height grid dumped from a VANILLA twin
(`height_dump_probe.lua` -> `out/height-<tag>-surface.raw`), so a design iteration costs
seconds instead of a 3-minute game run.

Algorithm (task contract `_ralph/tasks/full-z-parity.md`):

  1. shift measured on the INTERIOR of the source grid (one cell of border excluded --
     the rim holds resample/generation artifacts):
        shift   = 1000 - floor(interior_min * 4/3)
        src_cap = floor((65535 - shift) * 3/4)
  2. overflow zones = connected components of (h > src_cap).
  3. per-zone base: a level below src_cap, chosen per `--rule` (see BASE RULES).
  4. in-zone remap, applied to the connected component at the base level, for cells at or
     above the base:
        base_img = floor(base * 4/3) + shift        (the affine image of the base)
        H        = 65535 - base_img,  T = peak - base
        f(t)     = H * (1 - exp(-k t)) / (1 - exp(-k T)),  k solved so f'(0) = 4/3
        img(h)   = base_img + round(f(h - base))
     => value-continuous and slope-continuous with the affine at the base (no crease),
        monotone, and the massif's own peak lands EXACTLY on 65535.  The average in-zone
        slope factor is exactly (src_cap - base) / (peak - base).
  5. everywhere else: img(h) = floor(h * 4/3) + shift.

BASE RULES (`--rule`, all measured and reported side by side by `--rules-report`):
  knee      the contract's topological-persistence descent, but at fine step: base is the
            last level before the component that contains the peak grows by more than
            `--growth` in one step (a flood past the saddle).
  area      base is the last level before that component exceeds `--area-mult` x its
            above-cap area.
  headroom  base = src_cap - `--headroom` x (peak - src_cap): a fixed average in-zone slope
            factor of c/(1+c), no descent needed.

Massifs: several overflow components can share one connected component at the base level.
They are merged into a single massif with one base and one peak, so exactly one cell per
massif lands on 65535 and no cell is remapped twice.

Grid index convention: offset = y * width + x (GridSaveRaw row-major); bounding boxes are
[x0, y0, x1, y1) in source cells.

Usage:
    python zonefit.py --raw out/height-zq04-surface.raw --width 6144 \
        --json <out.json> [--fig <out.png>] [--simulate] [--rule area]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np
from scipy import ndimage
from scipy.optimize import brentq

CAP = 65535
FLOOR_MARGIN = 1000
XY_MUL, XY_DIV = 8192, 6144  # destination / source tiles; ratio exactly 4/3
TARGET_SLOPE = XY_MUL / XY_DIV


def affine(h, shift):
    """The engine's GridMulDivAdd image: floor(h * 8192/6144) + shift."""
    return (np.asarray(h, dtype=np.int64) * XY_MUL) // XY_DIV + shift


def load_grid(path, width, height=None):
    height = height or width
    raw = np.fromfile(path, dtype="<u2")
    if raw.size != width * height:
        raise SystemExit(
            f"{path}: {raw.size} u16 values, expected {width * height} ({width}x{height})"
        )
    return raw.reshape((height, width))


def solve_k(H, T):
    """k > 0 with H*k/(1-exp(-k*T)) = 4/3 (i.e. f'(0) = 4/3).

    f'(0) = H*k/(1-e^{-kT}) increases in k with limit H/T at k->0+, so a root exists iff
    H/T < 4/3 -- exactly the statement that the massif overflows above its base.  Returns
    0.0 for the degenerate no-compression case (caller then uses the linear ramp).
    """
    if T <= 0 or H <= 0:
        return 0.0
    if H / T >= TARGET_SLOPE:
        return 0.0

    def g(k):
        return H * k / -np.expm1(-k * T) - TARGET_SLOPE

    hi = 1e-9
    while g(hi) < 0:
        hi *= 2.0
        if hi > 1e6:
            raise RuntimeError(f"solve_k failed to bracket (H={H}, T={T})")
    return float(brentq(g, 1e-12, hi, xtol=1e-18, rtol=1e-15, maxiter=500))


def zone_lut(base, peak, shift):
    """Integer remap table for source values base..peak (index h-base)."""
    base = int(base)
    peak = int(peak)
    base_img = int(affine(base, shift))
    H = CAP - base_img
    T = peak - base
    k = solve_k(H, T)
    t = np.arange(0, max(T, 0) + 1, dtype=np.float64)
    if k <= 0.0:
        img = base_img + np.rint(H * t / max(T, 1)).astype(np.int64)
    else:
        img = base_img + np.rint(H * (-np.expm1(-k * t)) / -np.expm1(-k * T)).astype(np.int64)
    d = np.diff(img)
    meta = dict(
        base=base, peak=peak, base_img=base_img, H=int(H), T=int(T), k=k,
        peak_img=int(img[-1]),
        avg_slope=round(H / T, 6) if T > 0 else None,
        slope_factor=round((H / T) / TARGET_SLOPE, 6) if T > 0 else None,
        # measured slope over the first/last 64 steps: the numeric no-crease check
        slope_at_base=round(float(img[min(64, T)] - img[0]) / max(1, min(64, T)), 6) if T > 0 else None,
        slope_at_peak=round(float(img[-1] - img[max(0, T - 64)]) / max(1, min(64, T)), 6) if T > 0 else None,
        monotone=bool(np.all(d >= 0)) if T > 0 else True,
    )
    return meta, img


# --------------------------------------------------------------------------- descent


def crop_for(bbox, shape, pad):
    x0, y0, x1, y1 = bbox
    gh, gw = shape
    return (max(0, y0 - pad), min(gh, y1 + pad), max(0, x0 - pad), min(gw, x1 + pad))


def component_at(sub, level, py, px, structure):
    """(mask, area, escaped) for the >=level component of `sub` containing (py, px)."""
    lab, _ = ndimage.label(sub >= level, structure=structure)
    want = lab[py, px]
    if want == 0:
        return None, 0, False
    mask = lab == want
    escaped = bool(mask[0, :].any() or mask[-1, :].any() or mask[:, 0].any() or mask[:, -1].any())
    return mask, int(mask.sum()), escaped


def fine_curve(grid, zone, src_cap, structure, pad, steps, span_mult, log):
    """Area-vs-level curve for one overflow zone, measured on a padded crop.

    Descends from src_cap to src_cap - span_mult*(peak - src_cap) in `steps` steps.
    Each sample records the area of the component containing the peak and whether that
    component has reached the crop border (below which the sample is a lower bound).
    """
    y0, y1, x0, x1 = crop_for(zone["bbox"], grid.shape, pad)
    sub = grid[y0:y1, x0:x1]
    py, px = zone["peak_y"] - y0, zone["peak_x"] - x0
    over = max(1, zone["peak_src"] - src_cap)
    lo = max(1, src_cap - int(span_mult * over))
    step = max(1, (src_cap - lo) // steps)
    curve = []
    level = src_cap
    while level >= lo:
        _, area, escaped = component_at(sub, level, py, px, structure)
        curve.append((int(level), int(area), bool(escaped)))
        level -= step
    return dict(crop=[x0, y0, x1, y1], pad=pad, step=step, lo=lo,
                samples=[[l, a, int(e)] for l, a, e in curve])


def pick_base(curve, zone, src_cap, rule, growth, area_mult, headroom):
    """Base level for one zone under `rule`; returns (base, why)."""
    samples = curve["samples"]
    if rule == "headroom":
        over = max(1, zone["peak_src"] - src_cap)
        return max(1, src_cap - int(round(headroom * over))), f"src_cap - {headroom}*over"
    prev_level, prev_area = samples[0][0], max(1, samples[0][1])
    for level, area, escaped in samples[1:]:
        if rule == "knee" and area > prev_area * growth:
            return prev_level, f"flood x{area / prev_area:.2f} below {prev_level}"
        if rule == "area" and area > area_mult * max(1, zone["area_over_cap"]):
            return prev_level, f"area {area} > {area_mult}x{zone['area_over_cap']} below {prev_level}"
        if escaped:
            return prev_level, f"component escaped the crop below {prev_level}"
        prev_level, prev_area = level, max(1, area)
    return prev_level, "descent bottom reached"


def build_massifs(grid, zones, bases, structure, pad, log):
    """Merge zones that share a component at their base level.

    Highest peak first: a zone's base-level component absorbs every other zone whose peak
    lies inside it, and the massif keeps the base of its highest peak.
    """
    order = sorted(range(len(zones)), key=lambda i: -zones[i]["peak_src"])
    assigned = {}
    massifs = []
    for i in order:
        if i in assigned:
            continue
        z = zones[i]
        base = int(bases[i])
        y0, y1, x0, x1 = crop_for(z["bbox"], grid.shape, pad)
        sub = grid[y0:y1, x0:x1]
        mask, area, escaped = component_at(sub, base, z["peak_y"] - y0, z["peak_x"] - x0, structure)
        members = [i]
        for j in range(len(zones)):
            if j == i or j in assigned:
                continue
            zy, zx = zones[j]["peak_y"], zones[j]["peak_x"]
            if y0 <= zy < y1 and x0 <= zx < x1 and mask is not None and mask[zy - y0, zx - x0]:
                members.append(j)
        for j in members:
            assigned[j] = len(massifs)
        peak_src = int(sub[mask].max()) if mask is not None else z["peak_src"]
        massifs.append(dict(
            members=[j + 1 for j in members], base_src=base, peak_src=peak_src,
            peak_y=z["peak_y"], peak_x=z["peak_x"],
            base_area=int(area), base_escaped=bool(escaped),
            crop=[x0, y0, x1, y1],
        ))
    return massifs


# --------------------------------------------------------------------------- main


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--raw", required=True, help="vanilla surface height grid, raw U16")
    ap.add_argument("--width", type=int, default=6144)
    ap.add_argument("--height", type=int, default=0)
    ap.add_argument("--dest-width", type=int, default=8192)
    ap.add_argument("--connectivity", type=int, choices=(4, 8), default=8)
    ap.add_argument("--rule", choices=("knee", "area", "headroom"), default="area")
    ap.add_argument("--growth", type=float, default=3.0)
    ap.add_argument("--area-mult", type=float, default=8.0)
    ap.add_argument("--headroom", type=float, default=1.0)
    ap.add_argument("--pad", type=int, default=512, help="crop padding in source cells")
    ap.add_argument("--steps", type=int, default=96, help="descent samples per zone")
    ap.add_argument("--span-mult", type=float, default=4.0,
                    help="descend to src_cap - span_mult*(peak-src_cap)")
    ap.add_argument("--coarse", action="store_true",
                    help="also run the contract's literal coarse descent for comparison")
    ap.add_argument("--json", default="")
    ap.add_argument("--fig", default="")
    ap.add_argument("--simulate", action="store_true")
    ap.add_argument("--label", default="")
    args = ap.parse_args(argv)

    def log(*a):
        print(*a, flush=True)

    grid = load_grid(args.raw, args.width, args.height or args.width)
    gh, gw = grid.shape
    full_min, full_max = int(grid.min()), int(grid.max())
    interior = grid[1:-1, 1:-1]
    src_min, src_max = int(interior.min()), int(interior.max())
    shift = FLOOR_MARGIN - int(affine(src_min, 0))
    src_cap = int(((CAP - shift) * XY_DIV) // XY_MUL)
    affine_max = int(affine(src_max, shift))
    log(f"grid {gw}x{gh}  full {full_min}..{full_max}  interior {src_min}..{src_max}")
    log(f"shift {shift}  src_cap {src_cap}  affine_max {affine_max}  overflow {affine_max - CAP}")

    structure = ndimage.generate_binary_structure(2, 1 if args.connectivity == 4 else 2)
    over = grid > src_cap
    lab, nzones = ndimage.label(over, structure=structure)
    counts = np.bincount(lab.ravel())
    boxes = ndimage.find_objects(lab)
    peakpos = ndimage.maximum_position(grid, lab, range(1, nzones + 1))
    peakval = ndimage.maximum(grid, lab, range(1, nzones + 1))
    order = sorted(range(nzones), key=lambda i: -counts[i + 1])
    log(f"overflow cells {int(over.sum())} ({100.0 * over.sum() / over.size:.4f}%)  zones {nzones}")

    zones = []
    for n, i in enumerate(order):
        sl = boxes[i]
        py, px = (int(v) for v in peakpos[i])
        zones.append(dict(
            id=n + 1, label=int(i + 1), area_over_cap=int(counts[i + 1]),
            peak_src=int(peakval[i]), peak_y=py, peak_x=px,
            over_by=int(affine(peakval[i], shift) - CAP),
            bbox=[int(sl[1].start), int(sl[0].start), int(sl[1].stop), int(sl[0].stop)],
        ))

    # --- per-zone fine descent curves
    log("fine descent per zone")
    curves = []
    for z in zones:
        c = fine_curve(grid, z, src_cap, structure, args.pad, args.steps, args.span_mult, log)
        curves.append(c)
        s = c["samples"]
        log(f"  zone {z['id']:2d} peak {z['peak_src']} over {z['peak_src']-src_cap:5d} "
            f"area@cap {z['area_over_cap']:6d} step {c['step']:4d} "
            f"area@{s[len(s)//2][0]} {s[len(s)//2][1]} area@{s[-1][0]} {s[-1][1]} "
            f"escaped {any(x[2] for x in s)}")

    # --- candidate base rules, side by side
    rules_report = {}
    for rule in ("knee", "area", "headroom"):
        rows = []
        total = 0
        for z, c in zip(zones, curves):
            b, why = pick_base(c, z, src_cap, rule, args.growth, args.area_mult, args.headroom)
            area = next((a for l, a, _ in c["samples"] if l <= b), None)
            factor = (src_cap - b) / max(1, z["peak_src"] - b)
            total += area or 0
            rows.append(dict(zone=z["id"], base=int(b), base_area=area,
                             slope_factor=round(factor, 4), why=why))
        rules_report[rule] = dict(
            zones=rows, total_base_area=int(total),
            pct_of_map=round(100.0 * total / (gw * gh), 4),
            min_slope_factor=round(min(r["slope_factor"] for r in rows), 4),
        )
        log(f"rule {rule:8s}: total base area {total} ({rules_report[rule]['pct_of_map']:.3f}% of map), "
            f"worst slope factor {rules_report[rule]['min_slope_factor']:.3f}")

    # --- chosen rule -> massifs -> LUTs
    bases = [pick_base(c, z, src_cap, args.rule, args.growth, args.area_mult, args.headroom)[0]
             for z, c in zip(zones, curves)]
    massifs = build_massifs(grid, zones, bases, structure, args.pad, log)
    log(f"rule {args.rule}: {len(massifs)} massifs from {len(zones)} overflow zones")
    for m in massifs:
        meta, lut = zone_lut(m["base_src"], m["peak_src"], shift)
        m.update(meta)
        m["compression_at_peak"] = int(affine(m["peak_src"], shift) - meta["peak_img"])
        log(f"  massif {m['members']}: base {m['base_src']} -> {m['base_img']}, "
            f"peak {m['peak_src']} -> {m['peak_img']}, area {m['base_area']}, "
            f"k {m['k']:.3e}, slope base {m['slope_at_base']:.4f} peak {m['slope_at_peak']:.4f}, "
            f"avg factor {m['slope_factor']:.3f}, monotone {m['monotone']}, "
            f"escaped {m['base_escaped']}")

    report = dict(
        schema="smr.zonefit", schema_version=2, label=args.label,
        argv=dict(rule=args.rule, growth=args.growth, area_mult=args.area_mult,
                  headroom=args.headroom, pad=args.pad, steps=args.steps,
                  span_mult=args.span_mult, connectivity=args.connectivity),
        source=dict(raw=os.path.abspath(args.raw), width=gw, height=gh,
                    full_min=full_min, full_max=full_max,
                    interior_min=src_min, interior_max=src_max),
        transform=dict(xy_mul=XY_MUL, xy_div=XY_DIV, floor_margin=FLOOR_MARGIN,
                       shift=shift, src_cap=src_cap, affine_max=affine_max,
                       overflow_above_cap=affine_max - CAP),
        overflow=dict(cells=int(over.sum()),
                      pct=round(100.0 * float(over.sum()) / over.size, 6), zones=nzones),
        zones=zones, curves=curves, rules=rules_report, massifs=massifs,
    )

    if args.coarse:
        report["coarse_literal"] = coarse_descend(grid, zones, src_cap, src_min, structure,
                                                  args.growth, log)
    if args.simulate:
        report["simulation"] = simulate(grid, massifs, shift, src_cap, args.dest_width,
                                        structure, args.pad, log)
    if args.fig:
        make_figure(grid, lab, zones, curves, massifs, rules_report, shift, src_cap,
                    args.fig, args.rule, log)
        report["figure"] = os.path.abspath(args.fig)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=1, sort_keys=True)
        log(f"wrote {args.json}")
    return 0


def coarse_descend(grid, zones, src_cap, src_min, structure, growth, log):
    """The contract's literal descent: whole-grid labelling, step (src_cap-src_min)/40.

    Kept because it is what produced the contract's measured expectation; the fine
    per-zone curves supersede it.
    """
    step = max(64, (src_cap - src_min) // 40)
    n = len(zones)
    peaks = [(z["peak_y"], z["peak_x"]) for z in zones]
    bases = [None] * n
    prev = [None] * n
    lab, _ = ndimage.label(grid > src_cap, structure=structure)
    counts = np.bincount(lab.ravel())
    for i, (py, px) in enumerate(peaks):
        prev[i] = int(counts[lab[py, px]])
    level = src_cap
    trace = [[] for _ in range(n)]
    while any(b is None for b in bases) and level - step > src_min:
        level -= step
        lab, _ = ndimage.label(grid >= level, structure=structure)
        counts = np.bincount(lab.ravel())
        for i in range(n):
            if bases[i] is not None:
                continue
            area = int(counts[lab[peaks[i][0], peaks[i][1]]])
            trace[i].append([level, area])
            if prev[i] > 0 and area > prev[i] * growth:
                bases[i] = level + step
            else:
                prev[i] = area
    out = dict(step=int(step), growth=growth,
               bases=[int(b) if b is not None else None for b in bases],
               trace={str(i + 1): trace[i] for i in range(n)})
    log(f"coarse literal descent: step {step}, bases {out['bases']}")
    return out


def bilinear_up(grid, dest_w, dest_h):
    """Reference upsample: dest sample i reads source coordinate i * src/dest.

    GridResample's exact convention is unverified; this is the plain scale convention and is
    used ONLY to predict destination-space behaviour.  The authoritative destination values
    come from the expanded twin's own dump.
    """
    gh, gw = grid.shape
    ys = np.arange(dest_h, dtype=np.float64) * (gh / dest_h)
    xs = np.arange(dest_w, dtype=np.float64) * (gw / dest_w)
    y0 = np.clip(np.floor(ys).astype(np.int64), 0, gh - 1)
    x0 = np.clip(np.floor(xs).astype(np.int64), 0, gw - 1)
    y1 = np.minimum(y0 + 1, gh - 1)
    x1 = np.minimum(x0 + 1, gw - 1)
    fy = (ys - y0)[:, None]
    fx = (xs - x0)[None, :]
    g = grid.astype(np.float64)
    top = g[np.ix_(y0, x0)] * (1 - fx) + g[np.ix_(y0, x1)] * fx
    bot = g[np.ix_(y1, x0)] * (1 - fx) + g[np.ix_(y1, x1)] * fx
    return top * (1 - fy) + bot * fy


def simulate(grid, massifs, shift, src_cap, dest_w, structure, pad, log):
    """Apply the transform in DESTINATION space and verify the gate conditions there.

    Zones are re-discovered on the resampled grid, exactly as the mod must do: the
    destination peak of a massif is generally NOT the source peak (only 1 destination
    sample in 9 lands on a source cell), so the per-massif k is solved against the
    destination peak -- that is what makes the peak land exactly on the cap.
    """
    gh, gw = grid.shape
    dest_h = int(round(gh * dest_w / gw))
    scale = dest_w / gw
    log(f"simulating destination {dest_w}x{dest_h} (bilinear scale convention)")
    dsrc = np.rint(bilinear_up(grid, dest_w, dest_h)).astype(np.int64)
    img = affine(dsrc, shift)
    aff = img.copy()
    remapped = np.zeros(dsrc.shape, dtype=bool)
    dpad = int(pad * scale)
    out = []
    for m in massifs:
        base = int(m["base_src"])
        py = int(round(m["peak_y"] * scale))
        px = int(round(m["peak_x"] * scale))
        y0 = max(0, int(m["crop"][1] * scale) - dpad)
        y1 = min(dest_h, int(math.ceil(m["crop"][3] * scale)) + dpad)
        x0 = max(0, int(m["crop"][0] * scale) - dpad)
        x1 = min(dest_w, int(math.ceil(m["crop"][2] * scale)) + dpad)
        sub = dsrc[y0:y1, x0:x1]
        # snap the destination peak to the local maximum near the mapped source peak
        wy0, wy1 = max(0, py - y0 - 4), min(sub.shape[0], py - y0 + 5)
        wx0, wx1 = max(0, px - x0 - 4), min(sub.shape[1], px - x0 + 5)
        wmax = int(sub[wy0:wy1, wx0:wx1].max())
        wpos = np.argwhere(sub[wy0:wy1, wx0:wx1] == wmax)[0]
        ppy, ppx = wy0 + int(wpos[0]), wx0 + int(wpos[1])
        mask, area, escaped = component_at(sub, base, ppy, ppx, structure)
        if mask is None:
            out.append(dict(members=m["members"], error="component not found"))
            continue
        peak = int(sub[mask].max())
        meta, lut = zone_lut(base, peak, shift)
        sel = mask & (sub >= base)
        vals = np.clip(sub[sel] - base, 0, meta["T"])
        isub = img[y0:y1, x0:x1]
        isub[sel] = lut[vals]
        img[y0:y1, x0:x1] = isub
        rsub = remapped[y0:y1, x0:x1]
        rsub |= sel
        remapped[y0:y1, x0:x1] = rsub
        out.append(dict(members=m["members"], base_src=base, dest_peak_src=peak,
                        source_peak_src=m["peak_src"], dest_area=int(sel.sum()),
                        dest_escaped=bool(escaped), k=meta["k"], base_img=meta["base_img"],
                        peak_img=meta["peak_img"], peak_at_cap=bool(meta["peak_img"] == CAP),
                        monotone=meta["monotone"], slope_at_base=meta["slope_at_base"],
                        slope_factor=meta["slope_factor"],
                        bbox=[x0, y0, x1, y1]))
        log(f"  massif {m['members']}: dest peak {peak} (src {m['peak_src']}), "
            f"cells {int(sel.sum())}, peak_img {meta['peak_img']}, "
            f"escaped {escaped}")

    res = dict(dest_width=dest_w, dest_height=dest_h,
               remapped_cells=int(remapped.sum()),
               remapped_pct=round(100.0 * float(remapped.sum()) / (dest_w * dest_h), 6),
               img_min=int(img.min()), img_max=int(img.max()),
               over_cap_after=int((img > CAP).sum()), below_zero_after=int((img < 0).sum()),
               affine_max_before=int(aff.max()),
               affine_over_cap_cells=int((aff > CAP).sum()),
               peaks_at_cap=sum(1 for z in out if z.get("peak_at_cap")),
               massifs=out)
    res["outside_zone_affine_exact"] = bool(np.array_equal(img[~remapped], aff[~remapped]))
    res["outside_zone_over_cap"] = int((aff[~remapped] > CAP).sum())
    inside = img[remapped]
    res["inside_zone_compressed_only"] = bool(np.all(inside <= aff[remapped]))
    res["inside_zone_min_vs_base"] = int(inside.min()) if inside.size else 0
    log(f"  remapped {res['remapped_cells']} cells ({res['remapped_pct']:.4f}%), "
        f"img max {res['img_max']}, over-cap {res['over_cap_after']}, "
        f"peaks at cap {res['peaks_at_cap']}/{len(out)}, "
        f"outside-affine-exact {res['outside_zone_affine_exact']}, "
        f"outside-over-cap {res['outside_zone_over_cap']}")
    return res


def make_figure(grid, lab, zones, curves, massifs, rules, shift, src_cap, path, rule, log):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    step = 6
    small = grid[::step, ::step]
    mask = lab[::step, ::step] > 0
    fig = plt.figure(figsize=(17, 8.5), dpi=110)
    ax = fig.add_subplot(1, 2, 1)
    ax.imshow(small, cmap="gist_earth", interpolation="nearest")
    ov = np.zeros(small.shape + (4,), dtype=np.float32)
    ov[mask] = (1.0, 0.1, 0.1, 0.9)
    ax.imshow(ov, interpolation="nearest")
    for m in massifs[:8]:
        ax.text(m["peak_x"] / step, m["peak_y"] / step, ",".join(str(v) for v in m["members"]),
                color="yellow", fontsize=7, ha="center", va="center")
    ax.set_title(f"vanilla surface height {grid.shape[1]}x{grid.shape[0]} (1/{step}), "
                 f"{len(zones)} cells>src_cap={src_cap} in red\n"
                 f"{len(massifs)} massifs after base-level merge (rule '{rule}')")
    ax.set_xticks([]); ax.set_yticks([])

    ax2 = fig.add_subplot(2, 2, 2)
    for n in range(min(6, len(curves))):
        s = curves[n]["samples"]
        ax2.semilogy([x[0] for x in s], [max(1, x[1]) for x in s], lw=1.1,
                     label=f"zone {zones[n]['id']}")
    for m in massifs[:6]:
        ax2.axvline(m["base_src"], ls=":", lw=0.8, color="gray")
    ax2.invert_xaxis()
    ax2.set_xlabel("threshold level (source units)")
    ax2.set_ylabel("area of the peak's component (cells)")
    ax2.set_title(f"fine descent: area vs level (dotted = chosen bases, rule '{rule}')\n"
                  f"rule totals: " + ", ".join(
                      f"{r}={rules[r]['pct_of_map']:.2f}%/f{rules[r]['min_slope_factor']:.2f}"
                      for r in rules))
    ax2.legend(fontsize=7, ncol=3)
    ax2.grid(alpha=0.3)

    ax3 = fig.add_subplot(2, 2, 4)
    m = massifs[0]
    _, lut = zone_lut(m["base_src"], m["peak_src"], shift)
    hs = np.arange(m["base_src"], m["peak_src"] + 1)
    ax3.plot(hs, affine(hs, shift), lw=1.0, ls="--", color="tab:red",
             label="pure 4/3 affine (overflows the cap)")
    ax3.plot(hs, lut, lw=1.5, color="tab:blue", label=f"massif remap (k={m['k']:.2e})")
    ax3.axhline(CAP, lw=0.8, color="k")
    ax3.axvline(m["base_src"], lw=0.8, ls=":", color="gray")
    ax3.set_xlabel("source height"); ax3.set_ylabel("destination height")
    ax3.set_title(f"in-zone remap, massif {m['members']}: base {m['base_src']}->{m['base_img']}, "
                  f"peak {m['peak_src']}->{m['peak_img']}\n"
                  f"slope at base {m['slope_at_base']:.3f} (target {TARGET_SLOPE:.3f}), "
                  f"at peak {m['slope_at_peak']:.3f}, avg factor {m['slope_factor']:.3f}")
    ax3.legend(fontsize=8)
    ax3.grid(alpha=0.3)

    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)
    log(f"wrote {path}")


if __name__ == "__main__":
    sys.exit(main())
