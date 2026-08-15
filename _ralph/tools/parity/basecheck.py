"""Score contract step 3 -- the per-massif BASE -- offline, on the mod's own stretch dumps.

Every other gate takes the stamped `base` as given: `zonecheck` rebuilds each massif as the
component of (pre >= base) and scores the LUT above it, `creasecheck` scores the join AT it,
`shiftcheck` only checks base <= src_cap.  Nothing has ever scored WHERE the base was put.

The contract's step 3 asks for a topological-persistence base: descend the threshold from the
peak in steps of ~(src_cap - src_min)/40 and stop at "the last level before growth exceeds x3",
i.e. just before the set floods past the mountain's saddle into its neighbours.  Iteration 001
measured that literal rule unusable on this map (the peaks belong to giant connected highlands,
bases end up so deep that >= 6.6% of the map is remapped) and the port ships a bounded band
instead, `base = src_cap - ceil(Z_BAND_MULT * (peak - src_cap))` with Z_BAND_MULT = 1/3.  That
substitution has never been scored, and the intent behind persistence -- do not flood past the
saddle -- is a property the shipped base either has or does not have.  This tool measures it.

Clauses, all on the PRE grid (the destination-sized grid straight out of GridResample: exactly
the values the mod's own zone discovery ran on, in source height units):

  rule       every stamped base equals the port's rule, recomputed here from the PRE grid
             rather than from a closed form: the bounded band max(1, src_cap -
             ceil(BAND*(peak - src_cap))) with BAND = 1/3, CLAMPED UP to the saddle where
             that band would flood -- descend the contract's ladder from src_cap, and at the
             first step that grows past x3 bisect the interval to unit resolution, keeping the
             deepest level still within x3 of the last good one (v813; before it, the band
             alone).  Controls: BAND = 1/4 and BAND = 1/2 must move rows, and the unclamped
             band must differ on exactly the massifs whose stamp says it flooded.
  no_flood   descending the contract's own ladder from src_cap to the shipped base, the area of
             the 4-connected component holding the massif's peak never grows by more than x3 in
             one step.  This is the contract's persistence criterion read on the band the port
             actually compresses: if it holds, the shipped massif is confined to its own
             mountain and never spilled past a saddle, which is what step 3 exists to guarantee.
  headroom   how much further the threshold could descend below the shipped base before that
             x3 flood happens: the flood level, the margin in source units and in ladder steps,
             and the area the massif would then reach.  Diagnostic, and the number that says
             how much the shipped rule differs from the literal one.
  literal    the literal persistence base (the last ladder level before the flood) and the map
             coverage it would produce, per massif and summed as a union mask -- iteration 001
             surveyed this at 42S28W only, on the 6144^2 SOURCE grid; here it is measured in
             destination space at every coordinate dumped, which is the evidence the user's
             design call on step 3 needs.
  disjoint   the massif masks are pairwise disjoint (the port composites them one at a time with
             GridLerp; an overlap would silently apply one LUT to another massif's cells).
  monotone   every massif's LUT is non-decreasing, verified from the stamped parameters here
             rather than trusted from the mod's own `monotone=` flag, which is what
             `zonecheck.zones.all_monotone` reads today.  Control: a perturbed table must fail.

A map with no overflow stamps zero massifs (the compression loop never runs); step 3 does not
apply there and the case reports applicable=false rather than a vacuous green.

Usage:
  python basecheck.py --case label=42S28W,pre=out/stretch-t47x-surface-pre.raw,\
stamp=out/height-t47x-zones.txt [--case ...] --out <json> [--fig <png>]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np
from scipy import ndimage

from zonecheck import CAP, XY_DIV, XY_MUL, load, lut_for, parse_stamp

BAND_MULT = 1.0 / 3.0          # the port's Z_BAND_MULT (sbm_terrain_copy.lua)
FLOOD_RATIO = 3.0              # the contract's "growth exceeds x3"
LADDER_STEPS = 40              # the contract's "steps of ~(src_cap - src_min)/40"
MAX_STEPS_BELOW_BASE = 16      # how far below the base the descent hunts for the flood
MAX_AREA_FRACTION = 0.08       # stop the descent once the component swallows this much map
STRUCT4 = ndimage.generate_binary_structure(2, 1)   # 4-connected, like GridEnumZones


def predicted_base(src_cap, peak, band):
    """The port's own rule, reproduced exactly (integer ceil on a positive quantity)."""
    over = max(1, peak - src_cap)
    return max(1, src_cap - int(math.ceil(band * over)))


def saddle_clamped_base(pre, m, src_cap, step, band=BAND_MULT):
    """The port's v813 base rule, recomputed from the grid: band base clamped up to the saddle.

    Mirrors `ZCompressOverflow` step for step -- the same ladder (from min(src_cap, peak) down
    to the band base), the same x3 flood test against the last good level, and the same integer
    bisection of the interval that flooded.  Returns (base, band_base, good_level, flood_level).
    """
    px, py, peak = m["peak_x"], m["peak_y"], m["peak"]
    bbox = (m["x0"], m["y0"], m["x1"], m["y1"])
    pad = max(64, (m["x1"] - m["x0"]) // 2)
    band_base = predicted_base(src_cap, peak, band)
    start = min(src_cap, peak)
    if step <= 0 or band_base >= start:
        return band_base, band_base, None, None

    def area_at(level):
        return peak_component(pre, level, px, py, bbox, pad)[0]

    levels, lvl = [start], start
    while lvl - step > band_base:
        lvl -= step
        levels.append(lvl)
    levels.append(band_base)

    good, good_area, flood = None, None, None
    for lvl in levels:
        area = area_at(lvl)
        if good_area and area / good_area > FLOOD_RATIO:
            flood = lvl
            break
        good, good_area = lvl, area
    if flood is None:
        return band_base, band_base, good, None
    lo, hi, ref = flood, good, FLOOD_RATIO * good_area
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if area_at(mid) > ref:
            lo = mid
        else:
            hi = mid
    return max(band_base, hi), band_base, good, flood


def peak_component(pre, level, px, py, bbox, pad):
    """Area+mask of the 4-connected component of (pre >= level) holding (px, py).

    Grown exactly the way the port grows its crop: contact with a crop side that CUTS THROUGH
    the grid means the component escaped and the crop must double; contact with the map's own
    border does not.
    """
    h, w = pre.shape
    x0, y0, x1, y1 = bbox
    while True:
        cx0, cy0 = max(0, x0 - pad), max(0, y0 - pad)
        cx1, cy1 = min(w, x1 + pad), min(h, y1 + pad)
        sub = pre[cy0:cy1, cx0:cx1] >= level
        lab, _ = ndimage.label(sub, structure=STRUCT4)
        want = lab[py - cy0, px - cx0]
        if not want:
            return 0, None, (cx0, cy0, cx1, cy1), False
        mask = lab == want
        whole = (cx0 == 0 and cy0 == 0 and cx1 == w and cy1 == h)
        escaped = ((cx0 > 0 and mask[:, 0].any()) or (cy0 > 0 and mask[0, :].any())
                   or (cx1 < w and mask[:, -1].any()) or (cy1 < h and mask[-1, :].any()))
        if not escaped or whole:
            return int(mask.sum()), mask, (cx0, cy0, cx1, cy1), bool(escaped and not whole)
        pad *= 2


def descend(pre, m, src_cap, step, map_cells, log):
    """The contract's descent for one massif, from src_cap down past the flood."""
    px, py = m["peak_x"], m["peak_y"]
    bbox = (m["x0"], m["y0"], m["x1"], m["y1"])
    pad = max(64, (m["x1"] - m["x0"]) // 2)
    base = m["base"]
    start = min(src_cap, m["peak"])
    levels = [start]
    lvl = start
    floor_lvl = base - MAX_STEPS_BELOW_BASE * step
    while lvl - step > floor_lvl:
        lvl -= step
        levels.append(lvl)
    if base not in levels:                      # the shipped base is always a scored level
        levels.append(base)
    levels = sorted(set(int(v) for v in levels if v >= 1), reverse=True)

    curve, prev_area, prev_level, prev_mask = [], None, None, None
    flood_level, flood_ratio, flood_area = None, None, None
    persistence_base, persistence_mask = None, None
    flood_pair = None                           # (mask before the flood, mask at the flood)
    worst_in_band, worst_in_band_level = 1.0, None
    for lvl in levels:
        area, mask, crop, escaped = peak_component(pre, lvl, px, py, bbox, pad)
        ratio = (area / prev_area) if prev_area else None
        curve.append(dict(level=int(lvl), area=int(area),
                          ratio=round(float(ratio), 4) if ratio else None,
                          escaped=bool(escaped)))
        if ratio is not None and lvl >= base and ratio > worst_in_band:
            worst_in_band, worst_in_band_level = float(ratio), int(lvl)
        if ratio is not None and ratio > FLOOD_RATIO and flood_level is None:
            flood_level, flood_ratio, flood_area = int(lvl), float(ratio), int(area)
            persistence_base = int(prev_level)
            flood_pair = (prev_mask, (mask, crop))
        if persistence_base is None:
            persistence_mask = (mask, crop)     # keep the last pre-flood component
        prev_area, prev_level, prev_mask = area, lvl, (mask, crop)
        if area > MAX_AREA_FRACTION * map_cells:
            break
    if flood_level is None:                     # never flooded within the hunt window
        persistence_base = int(levels[-1])
    row = dict(index=m["index"], base=base, peak=m["peak"], stamped_cells=m["cells"],
               band_depth=int(src_cap - base), worst_ratio_in_band=round(worst_in_band, 4),
               worst_ratio_level=worst_in_band_level,
               no_flood_in_band=bool(worst_in_band <= FLOOD_RATIO),
               flood_level=flood_level, flood_ratio=round(flood_ratio, 4) if flood_ratio else None,
               flood_area=flood_area,
               headroom_units=(base - flood_level) if flood_level is not None else None,
               headroom_steps=(round((base - flood_level) / step, 2)
                               if flood_level is not None else None),
               persistence_base=persistence_base,
               persistence_below_shipped=bool(persistence_base < base),
               curve=curve)
    return row, persistence_mask, flood_pair


def full_mask(shape, packed):
    """Lift a (mask, crop) pair back onto a whole-grid boolean."""
    out = np.zeros(shape, dtype=bool)
    if packed and packed[0] is not None:
        mask, (cx0, cy0, cx1, cy1) = packed
        out[cy0:cy1, cx0:cx1] |= mask
    return out


def spill_stats(pre, m, row, flood_pair, src_cap, zmul, zdiv, shift):
    """What a flood inside the band actually costs: the cells it dragged into the massif.

    `merged` is the set the flood step added at the moment of merging -- terrain that belongs to
    a NEIGHBOURING mountain, which contract objective 2 ("only mountains that would pierce the
    ceiling are compressed, individually") does not want compressed.  `total` is everything the
    shipped base holds beyond the last pre-flood component, i.e. the merged set plus whatever
    flank it grew afterwards.  For both, the height each cell LOSES against the pure 4/3 affine
    is the harm: those cells are inside a zone, so they are exempt from the exactness gate and
    their passability is recomputed rather than vanilla-equal.
    """
    if not flood_pair or flood_pair[0] is None:
        return None
    before = full_mask(pre.shape, flood_pair[0])
    at = full_mask(pre.shape, flood_pair[1])
    merged = at & ~before
    base_mask = full_mask(pre.shape, row.pop("_base_mask", None))
    total = base_mask & ~before
    table = lut_for(m["base"], m["peak"], m["base_img"], m["k"], shift)
    out = {}
    for name, sel in (("merged_at_flood", merged), ("total_beyond_pre_flood", total)):
        n = int(sel.sum())
        if not n:
            out[name] = dict(cells=0)
            continue
        vals = pre[sel]
        idx = np.clip(vals - m["base"], 0, len(table) - 1)
        lut_v = table[idx]
        aff = np.minimum(vals, src_cap) * zmul // zdiv + shift
        drop = np.maximum(aff - lut_v, 0)
        out[name] = dict(cells=n, pct_of_map=round(100.0 * n / pre.size, 4),
                         pre_min=int(vals.min()), pre_max=int(vals.max()),
                         cells_above_src_cap=int((vals > src_cap).sum()),
                         drop_max_wu=int(drop.max()), drop_median_wu=int(np.median(drop)),
                         drop_p90_wu=int(np.percentile(drop, 90)),
                         cells_dropped_over_100wu=int((drop > 100).sum()))
    return out


def score_case(label, pre_path, stamp_path, log):
    pre = load(pre_path, 8192).astype(np.int64)
    maps, massifs = parse_stamp(stamp_path)
    surf = maps.get("surface", {})
    shift = int(surf.get("zadd", 0))
    zmul, zdiv = int(surf.get("zmul", XY_MUL)), int(surf.get("zdiv", XY_DIV))
    src_cap = ((CAP - shift) * zdiv) // zmul
    massifs = [m for m in massifs if m["tag"] == "surface"]
    map_cells = pre.size
    interior = pre[1:-1, 1:-1]
    src_min = int(interior.min())
    step = max(1, (src_cap - src_min) // LADDER_STEPS)
    log(f"[{label}] massifs {len(massifs)} src_cap {src_cap} shift {shift} "
        f"interior min {src_min} ladder step {step}")
    case = dict(label=label, pre=os.path.abspath(pre_path), stamp=os.path.abspath(stamp_path),
                massifs=len(massifs), src_cap=src_cap, shift=shift, src_min=src_min,
                ladder_step=step, map_cells=int(map_cells),
                applicable=bool(massifs))
    if not massifs:
        case.update(note="no overflow: the compression loop never ran, so step 3 does not apply",
                    clauses={}, gate_ok=None)
        log(f"[{label}] N/A - zero massifs (degenerate branch)")
        return case

    # --- clause `rule`: the shipped base is the port's own saddle-clamped band, exactly
    rule_rows, rule_bad, clamped, ctl_unclamped = [], 0, 0, 0
    for m in massifs:
        want, band_base, good, flood = saddle_clamped_base(pre, m, src_cap, step)
        ok = (m["base"] == want)
        rule_bad += 0 if ok else 1
        clamped += 1 if want > band_base else 0
        ctl_unclamped += 0 if m["base"] == band_base else 1
        rule_rows.append(dict(index=m["index"], peak=m["peak"], base=m["base"],
                              predicted=want, band_base=band_base, clamped=bool(want > band_base),
                              ladder_good_level=good, flood_level=flood, ok=bool(ok)))
        if want > band_base:
            log(f"[{label}]  massif {m['index']:>3}: band base {band_base} CLAMPED to {want} "
                f"(flood at {flood} below the last good level {good})")
    ctl_quarter = sum(1 for m in massifs
                      if m["base"] != predicted_base(src_cap, m["peak"], 0.25))
    ctl_half = sum(1 for m in massifs
                   if m["base"] != predicted_base(src_cap, m["peak"], 0.5))

    # --- clause `monotone`: verified from the stamped parameters, not from the mod's flag
    mono_bad, mono_flag_disagree, ctl_mono = 0, 0, 0
    for m in massifs:
        table = lut_for(m["base"], m["peak"], m["base_img"], m["k"], shift)
        good = bool(np.all(np.diff(table) >= 0))
        mono_bad += 0 if good else 1
        mono_flag_disagree += 0 if good == m["monotone"] else 1
        bad = table.copy()                      # constructed control: one inversion
        if bad.size > 3:
            bad[len(bad) // 2] = int(bad[0])
            ctl_mono += 0 if np.all(np.diff(bad) >= 0) else 1

    # --- clauses `no_flood` / `headroom` / `literal`: the descent, one massif at a time
    rows, union = [], np.zeros(pre.shape, dtype=bool)
    shipped_union = np.zeros(pre.shape, dtype=bool)
    for m in massifs:
        row, pm, flood_pair = descend(pre, m, src_cap, step, map_cells, log)
        rows.append(row)
        area, mask, crop, _ = peak_component(pre, m["base"], m["peak_x"], m["peak_y"],
                                             (m["x0"], m["y0"], m["x1"], m["y1"]),
                                             max(64, (m["x1"] - m["x0"]) // 2))
        row["rebuilt_cells"] = int(area)
        row["cells_match_stamp"] = bool(area == m["cells"])
        if not row["no_flood_in_band"]:
            row["_base_mask"] = (mask, crop)
            row["spill"] = spill_stats(pre, m, row, flood_pair, src_cap, zmul, zdiv, shift)
            s = row["spill"]["total_beyond_pre_flood"] if row["spill"] else {}
            log(f"[{label}]   FLOOD massif {row['index']}: merged "
                f"{row['spill']['merged_at_flood']['cells']} cells at the flood step, "
                f"{s.get('cells')} cells ({s.get('pct_of_map')}% of the map) beyond the last "
                f"pre-flood component, dropping up to {s.get('drop_max_wu')} wu below the affine")
        if mask is not None:
            cx0, cy0, cx1, cy1 = crop
            row["overlap_cells"] = int((shipped_union[cy0:cy1, cx0:cx1] & mask).sum())
            shipped_union[cy0:cy1, cx0:cx1] |= mask
        if pm and pm[0] is not None:
            pmask, (cx0, cy0, cx1, cy1) = pm
            union[cy0:cy1, cx0:cx1] |= pmask
        log(f"[{label}]  massif {row['index']:>3}: base {row['base']} peak {row['peak']} "
            f"band {row['band_depth']} worst x{row['worst_ratio_in_band']} in band, "
            f"flood at {row['flood_level']} (x{row['flood_ratio']}), "
            f"headroom {row['headroom_units']} units")

    shipped_cells = int(shipped_union.sum())
    literal_cells = int(union.sum())
    overlap_total = sum(r.get("overlap_cells", 0) for r in rows)
    case["clauses"] = dict(
        rule=dict(massifs=len(massifs), mismatches=rule_bad, band_mult=BAND_MULT,
                  ok=bool(rule_bad == 0), control_band_quarter_moves=ctl_quarter,
                  control_band_half_moves=ctl_half, saddle_clamped_massifs=clamped,
                  control_unclamped_band_moves=ctl_unclamped, detail=rule_rows),
        monotone=dict(non_monotone_tables=mono_bad, stamp_flag_disagreements=mono_flag_disagree,
                      control_inversions_detected=ctl_mono, ok=bool(mono_bad == 0)),
        no_flood=dict(criterion=f"component area growth <= x{FLOOD_RATIO} per ladder step "
                                f"from src_cap down to the shipped base",
                      violations=sum(0 if r["no_flood_in_band"] else 1 for r in rows),
                      violating_massifs=[r["index"] for r in rows if not r["no_flood_in_band"]],
                      worst_ratio=max(r["worst_ratio_in_band"] for r in rows),
                      spill_cells=sum(r["spill"]["total_beyond_pre_flood"]["cells"]
                                      for r in rows if r.get("spill")),
                      spill_pct=round(100.0 * sum(r["spill"]["total_beyond_pre_flood"]["cells"]
                                                  for r in rows if r.get("spill")) / map_cells, 4),
                      ok=all(r["no_flood_in_band"] for r in rows)),
        headroom=dict(min_units=min((r["headroom_units"] for r in rows
                                     if r["headroom_units"] is not None), default=None),
                      min_steps=min((r["headroom_steps"] for r in rows
                                     if r["headroom_steps"] is not None), default=None),
                      massifs_that_never_flooded=sum(1 for r in rows
                                                     if r["flood_level"] is None)),
        literal=dict(persistence_cells=literal_cells,
                     persistence_pct=round(100.0 * literal_cells / map_cells, 4),
                     shipped_cells=shipped_cells,
                     shipped_pct=round(100.0 * shipped_cells / map_cells, 4),
                     ratio=round(literal_cells / max(shipped_cells, 1), 3),
                     note="union masks in destination space; the literal rule is the contract's "
                          "step 3, the shipped one is the port's bounded band"),
        disjoint=dict(overlap_cells=overlap_total,
                      sum_of_areas=sum(r["rebuilt_cells"] for r in rows),
                      union_cells=shipped_cells,
                      masks_match_stamp=sum(1 for r in rows if r["cells_match_stamp"]),
                      ok=bool(overlap_total == 0
                              and all(r["cells_match_stamp"] for r in rows))),
    )
    case["detail"] = rows
    c = case["clauses"]
    case["gate_ok"] = bool(c["rule"]["ok"] and c["monotone"]["ok"] and c["no_flood"]["ok"]
                           and c["disjoint"]["ok"]
                           and c["rule"]["control_band_quarter_moves"] == len(massifs)
                           and c["monotone"]["control_inversions_detected"] == len(massifs))
    log(f"[{label}] rule {len(massifs) - rule_bad}/{len(massifs)}, "
        f"no-flood {len(massifs) - c['no_flood']['violations']}/{len(massifs)} "
        f"(worst x{c['no_flood']['worst_ratio']}), monotone {len(massifs) - mono_bad}/"
        f"{len(massifs)}, overlap {overlap_total}, shipped {c['literal']['shipped_pct']}% vs "
        f"literal {c['literal']['persistence_pct']}% of the map -> "
        f"{'PASS' if case['gate_ok'] else 'FAIL'}")
    return case


def make_figure(report, path, log):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    cases = [c for c in report["cases"] if c.get("applicable")]
    fig = plt.figure(figsize=(17, 9), dpi=110)
    for i, case in enumerate(cases[:3]):
        ax = fig.add_subplot(2, 3, i + 1)
        for r in case["detail"]:
            lv = [p["level"] for p in r["curve"]]
            ar = [max(p["area"], 1) for p in r["curve"]]
            ax.plot(lv, ar, lw=0.7, alpha=0.65)
            ax.plot([r["base"]], [max(r["rebuilt_cells"], 1)], "o", ms=3, color="crimson")
            if r["flood_level"] is not None:
                ax.plot([r["flood_level"]], [max(r["flood_area"], 1)], "x", ms=4, color="k")
        ax.axvline(case["src_cap"], lw=0.9, color="tab:blue", ls="--")
        ax.set_yscale("log")
        ax.invert_xaxis()
        ax.set_xlabel("threshold (source height units), descending")
        ax.set_ylabel("peak-component area (cells)")
        ax.set_title(f"{case['label']}: {case['massifs']} massifs\n"
                     f"red = shipped base, x = first x3 flood, dashed = src_cap")
        ax.grid(alpha=0.3)

    ax = fig.add_subplot(2, 1, 2)
    ax.axis("off")
    lines = ["CONTRACT STEP 3 - the per-massif base, scored offline on the stretch dumps", ""]
    for case in report["cases"]:
        if not case.get("applicable"):
            lines.append(f"  {case['label']:<10} N/A - zero massifs (no overflow, step 3 "
                         f"does not apply)")
            continue
        c = case["clauses"]
        lines.append(
            f"  {case['label']:<10} {case['massifs']:>3} massifs   "
            f"rule {case['massifs'] - c['rule']['mismatches']}/{case['massifs']}   "
            f"no-flood {case['massifs'] - c['no_flood']['violations']}/{case['massifs']} "
            f"(worst x{c['no_flood']['worst_ratio']})   "
            f"monotone {case['massifs'] - c['monotone']['non_monotone_tables']}/"
            f"{case['massifs']}   overlap {c['disjoint']['overlap_cells']}")
        lines.append(
            f"  {'':<10} headroom below the shipped base >= {c['headroom']['min_units']} units "
            f"({c['headroom']['min_steps']} ladder steps)   "
            f"coverage shipped {c['literal']['shipped_pct']}% vs literal-persistence "
            f"{c['literal']['persistence_pct']}% (x{c['literal']['ratio']})")
        if c["no_flood"]["violations"]:
            lines.append(
                f"  {'':<10} FLOODED massifs {c['no_flood']['violating_massifs']}: "
                f"{c['no_flood']['spill_cells']:,} cells ({c['no_flood']['spill_pct']}% of the "
                f"map) dragged in past a saddle - compressed terrain that never pierced the "
                f"ceiling")
    lines += ["", "  controls: BAND=1/4 and BAND=1/2 move every row; a constructed table "
                  "inversion is caught on every massif;",
              "            the flood detector fires below the base on the same ladder that "
              "reports no flood inside the band."]
    ax.text(0.01, 0.98, "\n".join(lines), va="top", ha="left", fontsize=11, family="monospace")
    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)
    log(f"wrote {path}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", action="append", default=[],
                    help="label=<name>,pre=<stretch pre raw>,stamp=<zones txt>")
    ap.add_argument("--out", default="")
    ap.add_argument("--fig", default="")
    args = ap.parse_args(argv)

    def log(*a):
        print(*a, flush=True)

    cases = []
    for spec in args.case:
        d = dict(kv.split("=", 1) for kv in spec.split(","))
        cases.append(score_case(d["label"], d["pre"], d["stamp"], log))

    scored = [c for c in cases if c.get("applicable")]
    report = dict(schema="smr.basecheck", schema_version=1,
                  band_mult=BAND_MULT, flood_ratio=FLOOD_RATIO, ladder_steps=LADDER_STEPS,
                  cases=cases,
                  coordinates_scored=len(scored),
                  massifs_scored=sum(c["massifs"] for c in scored),
                  gate_ok=bool(scored and all(c["gate_ok"] for c in scored)))
    if args.fig:
        make_figure(report, args.fig, log)
        report["figure"] = os.path.abspath(args.fig)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=1, sort_keys=True)
        log(f"wrote {args.out}")
    log(f"STEP 3 {'PASS' if report['gate_ok'] else 'FAIL'} over "
        f"{report['massifs_scored']} massifs at {report['coordinates_scored']} coordinates")
    return 0 if report["gate_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
