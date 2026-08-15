"""Gate the mod's in-game Z transform against the vanilla twin, offline.

Inputs: the vanilla twin's SOURCE height grid (raw U16, 6144^2), the expanded twin's
DESTINATION height grid (raw U16, 8192^2) and the massif stamp the height probe writes
(`height-<tag>-zones.txt`, from `map.SuperBigMapZCompressionZones`).

WHAT CAN AND CANNOT BE SCORED CELL-EXACTLY.  The destination grid is GridResample(source), and
that resampler's exact arithmetic is NOT reproducible offline: measured against this pair, the
convention is the ENDPOINT one (dest i reads source i*(6143/8191), not i*3/4 -- the plain
convention is off by up to 72 height units, the endpoint one by at most 2), but no rounding
variant tried reproduces it bit for bit (best 68% of cells exact, mean 0.43, max 3).  So
`expanded == floor(vanilla*4/3) + shift` cannot be scored per cell until the pre-transform
destination grid itself is dumped.  What IS scored here, all of it exact:

  affine_image   outside every massif, (expanded - shift) must be a value the map
                 floor(d*4/3) can produce.  That map never produces (img - shift) % 4 == 3,
                 so a quarter of all wrong values are caught, over 66M cells -- any transform
                 that is not this affine lights it up immediately.
  lut_image      inside a massif, the value must be one its own LUT can produce, and must lie
                 in [base_img, 65535].
  peak_at_cap    each massif's rebuilt mask must top out at exactly 65535.
  cells          the mask rebuilt from the final grid must have exactly the cell count the mod
                 stamped (the mod counted it on the pre-transform grid, so agreement also
                 proves the transform preserved the base level set).
  no_crease      each massif's analytic slope at its base must be exactly 4/3.
  scale_residual the residual against the best offline resample model: a Z scale that was not
                 4/3 would show thousands of units of error here, not the resampler's own
                 couple of units.

Massif masks are rebuilt from the FINAL grid: the transform is monotone everywhere and equal
to the affine at the base, so {img >= base_img} == {h >= base}, and the massif is the
4-connected component of that set holding its stamped peak cell, inside its stamped bbox.

EXACT MODE (`--pre`, the mod's test-only stretch dump).  With the destination grid as it is
straight out of GridResample, the transform is scored between its own input and output and every
"cannot be reproduced offline" caveat above disappears: masks are rebuilt from `pre` (the same
grid the mod ran zone discovery on), and every cell is checked against the value the port must
have produced --

  outside every massif   post == max(0, floor(min(pre, src_cap) * zmul/zdiv) + shift)
                         (the port applies the affine to a source pre-clamped to src_cap and pins
                         cells whose affine would go negative to 0), and no cell may be over
                         src_cap in the first place -- an overflow cell that no massif claimed
                         would otherwise hide behind that clamp as a flat capped value.
  inside a massif        post == lut[pre] for its own stamped curve, exactly.

That is the contract's `height-similarity-outside-zones` gate, scored per cell.

Usage:
  python zonecheck.py --vanilla out/height-zq04-surface.raw \
      --expanded out/height-zx05-surface.raw --stamp out/height-zx05-zones.txt \
      --json <out.json> [--fig <out.png>]
  python zonecheck.py --pre out/stretch-zx06-surface-pre.raw \
      --expanded out/stretch-zx06-surface-post.raw --stamp out/height-zx06-zones.txt \
      --json <out.json> [--fig <out.png>]
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
            kind = parts[0]
            if kind == "map":
                d = {}
                for kv in parts[2:]:
                    k, _, v = kv.partition("=")
                    d[k] = v
                maps[parts[1]] = d
            elif kind == "massif":
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


def resample_model(van, dest_w, bits=8):
    """Best offline model of the engine's resample: endpoint convention, fixed-point bilinear.

    Diagnostic only -- it agrees with the engine on ~68% of cells and never by more than 3
    height units, which is enough to detect a wrong Z SCALE (thousands of units) but not to
    score a per-cell equality gate.
    """
    sh, sw = van.shape
    one, half = 1 << bits, 1 << (bits - 1)

    def axis(n, src):
        pos = (np.arange(n, dtype=np.int64) * (src - 1) * one) // (dest_w - 1)
        i0 = np.clip(pos >> bits, 0, src - 2)
        return i0, i0 + 1, pos - (i0 << bits)

    y0, y1, fy = axis(dest_w, sh)
    x0, x1, fx = axis(dest_w, sw)
    out = np.empty((dest_w, dest_w), dtype=np.int64)
    g = van.astype(np.int64)
    FX = fx[None, :]
    for row in range(dest_w):
        a = g[y0[row], x0] * (one - fx) + g[y0[row], x1] * fx
        b = g[y1[row], x0] * (one - fx) + g[y1[row], x1] * fx
        out[row] = (a * (one - fy[row]) + b * fy[row] + (1 << (2 * bits - 1))) >> (2 * bits)
    del FX
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vanilla", default="",
                    help="vanilla SOURCE grid; enables the resample-model diagnostic")
    ap.add_argument("--pre", default="",
                    help="destination grid straight out of GridResample (exact mode)")
    ap.add_argument("--expanded", required=True)
    ap.add_argument("--stamp", required=True)
    ap.add_argument("--src-width", type=int, default=6144)
    ap.add_argument("--dest-width", type=int, default=8192)
    ap.add_argument("--json", default="")
    ap.add_argument("--fig", default="")
    ap.add_argument("--label", default="")
    args = ap.parse_args(argv)

    def log(*a):
        print(*a, flush=True)

    if not args.vanilla and not args.pre:
        raise SystemExit("need --vanilla (heuristic mode) or --pre (exact mode)")
    van = load(args.vanilla, args.src_width) if args.vanilla else None
    pre = load(args.pre, args.dest_width) if args.pre else None
    exp = load(args.expanded, args.dest_width).astype(np.int64)
    maps, massifs = parse_stamp(args.stamp)
    surf = maps.get("surface", {})
    shift = int(surf.get("zadd", 0))
    zmul, zdiv = int(surf.get("zmul", XY_MUL)), int(surf.get("zdiv", XY_DIV))
    massifs = [m for m in massifs if m["tag"] == "surface"]
    src_cap = ((CAP - shift) * zdiv) // zmul
    log(f"mode {'EXACT (pre/post)' if pre is not None else 'heuristic'} "
        f"expanded {exp.shape} shift {shift} z {zmul}/{zdiv} "
        f"src_cap {src_cap} massifs {len(massifs)}")

    # --- massif masks.  In exact mode they are rebuilt from the PRE grid, i.e. from exactly the
    # values the mod's own zone discovery ran on; otherwise from the final grid (see the module
    # docstring for why that is equivalent but weaker).
    structure = ndimage.generate_binary_structure(2, 1)  # 4-connected, like GridEnumZones
    inzone = np.zeros(exp.shape, dtype=bool)
    rows = []
    lut_mismatch_total, pre_over_peak_total = 0, 0
    for m in massifs:
        y0, y1, x0, x1 = m["y0"], m["y1"], m["x0"], m["x1"]
        sub = exp[y0:y1, x0:x1]
        table = lut_for(m["base"], m["peak"], m["base_img"], m["k"], shift)
        if pre is not None:
            sub_pre = pre[y0:y1, x0:x1].astype(np.int64)
            lab, _ = ndimage.label(sub_pre >= m["base"], structure=structure)
        else:
            sub_pre = None
            lab, _ = ndimage.label(sub >= m["base_img"], structure=structure)
        want = lab[m["peak_y"] - y0, m["peak_x"] - x0]
        mask = (lab == want) if want else np.zeros(sub.shape, dtype=bool)
        area = int(mask.sum())
        inzone[y0:y1, x0:x1] |= mask
        vals = sub[mask]
        allowed = np.zeros(CAP + 1, dtype=bool)
        allowed[table] = True
        outside_image = int((~allowed[vals]).sum()) if area else 0
        below_base = int((vals < m["base_img"]).sum()) if area else 0
        lut_mismatch, pre_over_peak = None, None
        if sub_pre is not None and area:
            src_vals = sub_pre[mask]
            pre_over_peak = int((src_vals > m["peak"]).sum())
            idx = np.clip(src_vals - m["base"], 0, len(table) - 1)
            lut_mismatch = int((vals != table[idx]).sum())
            lut_mismatch_total += lut_mismatch
            pre_over_peak_total += pre_over_peak
        H, T, k = CAP - m["base_img"], m["peak"] - m["base"], m["k"]
        slope = (H * k / -math.expm1(-k * T)) if k > 0 and T > 0 else (H / T if T else None)
        rows.append(dict(index=m["index"], base=m["base"], base_img=m["base_img"],
                         peak_src=m["peak"], peak_img=m["peak_img"], k=m["k"],
                         stamped_cells=m["cells"], rebuilt_cells=area,
                         cells_match=bool(area == m["cells"]),
                         max_in_mask=int(vals.max()) if area else 0,
                         peak_at_cap=bool(area and int(vals.max()) == CAP),
                         values_outside_lut_image=outside_image, values_below_base=below_base,
                         lut_mismatch=lut_mismatch, pre_above_peak=pre_over_peak,
                         monotone=m["monotone"], escaped=m["escaped"],
                         slope_at_base=round(float(slope), 9) if slope else None,
                         bbox=[x0, y0, x1, y1]))
    zone_cells = int(inzone.sum())
    log(f"zone cells {zone_cells} ({100.0 * zone_cells / inzone.size:.4f}% of the map)")

    # --- outside the zones: every value must be one the affine floor(d*4/3)+shift can produce
    out_vals = exp[~inzone]
    bad_residue = int((((out_vals - shift) & 3) == 3).sum())
    over_cap_img = int((out_vals - shift > (src_cap * XY_MUL) // XY_DIV).sum())
    log(f"outside zones: {out_vals.size} cells, {bad_residue} values the 4/3 affine cannot "
        f"produce, {over_cap_img} above the affine image of src_cap")

    # --- where those values are.  Measured at 42S28W: they are not scattered noise but the
    # mod's OWN post-stretch terrain edits -- entrance/passage flatten pads and the landing pit,
    # which legitimately overwrite the transformed ground (the 5669..5811 x 3176..3301 cluster is
    # flat at 12287, exactly the Z of the UndergroundPassage standing on it).  A gate on the pure
    # transform therefore has to read the grid as it is right after the stretch, not at the end
    # of generation.
    bad_mask = np.zeros(exp.shape, dtype=bool)
    bad_mask[~inzone] = ((out_vals - shift) & 3) == 3
    lab, nclust = ndimage.label(bad_mask, structure=np.ones((3, 3), dtype=bool))
    sizes = np.bincount(lab.ravel())[1:] if nclust else np.zeros(0, dtype=np.int64)
    boxes = ndimage.find_objects(lab) if nclust else []
    top = np.argsort(-sizes)[:8] if nclust else []
    clusters = []
    for i in top:
        sl = boxes[i]
        patch = exp[sl]
        clusters.append(dict(cells=int(sizes[i]),
                             bbox=[int(sl[1].start), int(sl[0].start),
                                   int(sl[1].stop), int(sl[0].stop)],
                             patch_min=int(patch.min()), patch_max=int(patch.max()),
                             distinct_values=int(np.unique(patch).size)))
    log(f"  in {nclust} clusters; largest {clusters[0]['cells'] if clusters else 0} cells")

    # --- EXACT: outside every massif the port's own arithmetic, cell by cell.  The affine runs on
    # a source pre-clamped to src_cap and pins a negative image to 0, so the expected value is a
    # pure function of the pre value and can be evaluated as one 16-bit lookup over the whole grid.
    exact = None
    if pre is not None:
        h = np.arange(CAP + 1, dtype=np.int64)
        aff_lut = np.clip(np.minimum(h, src_cap) * zmul // zdiv + shift, 0, CAP).astype(np.uint16)
        expected = aff_lut[pre]
        wrong = (expected != exp.astype(np.uint16)) & ~inzone
        n_wrong = int(wrong.sum())
        over_cap_pre = int(((pre > src_cap) & ~inzone).sum())
        samples = []
        if n_wrong:
            ys, xs = np.nonzero(wrong)
            for i in range(min(8, n_wrong)):
                y, x = int(ys[i]), int(xs[i])
                samples.append(dict(x=x, y=y, pre=int(pre[y, x]), post=int(exp[y, x]),
                                    expected=int(expected[y, x])))
            diff = exp[wrong].astype(np.int64) - expected[wrong].astype(np.int64)
            worst = int(np.abs(diff).max())
        else:
            worst = 0
        exact = dict(outside_cells=int((~inzone).sum()), outside_mismatch=n_wrong,
                     outside_worst_abs=worst, outside_samples=samples,
                     pre_above_src_cap_outside=over_cap_pre,
                     inzone_lut_mismatch=lut_mismatch_total,
                     inzone_pre_above_peak=pre_over_peak_total,
                     ok=bool(n_wrong == 0 and over_cap_pre == 0
                             and lut_mismatch_total == 0 and pre_over_peak_total == 0))
        log(f"EXACT outside zones: {n_wrong} cells differ from "
            f"max(0, floor(min(pre, src_cap)*{zmul}/{zdiv}) + {shift}) "
            f"(worst |d| {worst}), {over_cap_pre} pre values above src_cap outside a massif; "
            f"inside zones: {lut_mismatch_total} cells off their LUT, "
            f"{pre_over_peak_total} pre values above the stamped peak")
        del expected, wrong

    # --- residual against the best offline resample model (scale sanity, not a per-cell gate)
    resid_report = None
    if van is not None:
        model = resample_model(van, args.dest_width)
        pred = (model * XY_MUL) // XY_DIV + shift
        resid = (exp - pred)[~inzone]
        resid_report = dict(model="endpoint fixed-point bilinear, 8-bit fraction",
                            mean_abs=round(float(np.abs(resid).mean()), 4),
                            max_abs=int(np.abs(resid).max()),
                            exact_pct=round(100.0 * float((resid == 0).mean()), 3),
                            note="diagnostic: the engine's resample arithmetic is not "
                                 "reproduced bit-exactly offline; a wrong Z scale would "
                                 "show thousands of units here")
        log(f"outside-zone residual vs the resample model: mean|d| {np.abs(resid).mean():.3f}, "
            f"max|d| {int(np.abs(resid).max())}, exact {100.0 * float((resid == 0).mean()):.2f}%")

    report = dict(
        schema="smr.zonecheck", schema_version=3, label=args.label,
        mode="exact" if pre is not None else "heuristic",
        inputs=dict(vanilla=os.path.abspath(args.vanilla) if args.vanilla else None,
                    pre=os.path.abspath(args.pre) if args.pre else None,
                    expanded=os.path.abspath(args.expanded),
                    stamp=os.path.abspath(args.stamp)),
        transform=dict(shift=shift, src_cap=src_cap, zmul=zmul, zdiv=zdiv,
                       is_similarity=bool(zmul * XY_DIV == zdiv * XY_MUL),
                       measured_max=surf.get("measured_max")),
        zones=dict(massifs=len(massifs), zone_cells=zone_cells,
                   pct_of_map=round(100.0 * zone_cells / inzone.size, 4),
                   peaks_at_cap=sum(1 for r in rows if r["peak_at_cap"]),
                   cells_match=sum(1 for r in rows if r["cells_match"]),
                   all_monotone=all(r["monotone"] for r in rows),
                   any_escaped=any(r["escaped"] for r in rows),
                   values_outside_lut_image=sum(r["values_outside_lut_image"] for r in rows),
                   values_below_base=sum(r["values_below_base"] for r in rows),
                   detail=rows),
        outside=dict(cells=int(out_vals.size), impossible_affine_values=bad_residue,
                     above_affine_of_src_cap=over_cap_img,
                     exact=bool(bad_residue == 0 and over_cap_img == 0),
                     impossible_clusters=int(nclust), largest_clusters=clusters,
                     note="the non-affine values are the mod's own post-stretch terrain "
                          "edits (entrance/passage flatten pads, landing pit), not transform "
                          "error; see the flat patch_min == patch_max clusters"),
        resample_residual=resid_report,
        exact=exact,
        final=dict(grid_max=int(exp.max()), grid_min=int(exp.min()),
                   cells_at_cap=int((exp == CAP).sum())),
        no_crease=dict(target_slope=round(TARGET_SLOPE, 9),
                       worst_abs_error=round(max(
                           [abs(r["slope_at_base"] - TARGET_SLOPE)
                            for r in rows if r["slope_at_base"]] or [0.0]), 12)),
    )
    # A map with no overflow takes the compression loop ZERO times, so the transform degenerates
    # to the pure similarity. Its final maximum then must NOT reach the ceiling - had it reached
    # it, an overflow existed and a massif was owed. Demanding grid_max == CAP there would fail a
    # correct zero-massif map; demanding grid_max < CAP is the same statement the massif branch
    # makes (every peak lands exactly on the cap), read on the branch that has no peaks.
    report["final"]["ceiling_rule"] = ("massif peaks land on the cap" if massifs
                                       else "no massif: the final max must stay below the cap")
    report["final"]["ceiling_ok"] = bool(report["final"]["grid_max"] == CAP if massifs
                                         else report["final"]["grid_max"] < CAP)
    ok = (report["outside"]["exact"]
          and (exact is None or exact["ok"])
          and report["transform"]["is_similarity"]
          and report["zones"]["peaks_at_cap"] == len(massifs)
          and report["zones"]["cells_match"] == len(massifs)
          and report["zones"]["values_outside_lut_image"] == 0
          and report["zones"]["all_monotone"]
          and report["final"]["ceiling_ok"]
          and report["no_crease"]["worst_abs_error"] < 1e-9)
    report["gate_ok"] = bool(ok)
    log(f"GATE {'PASS' if ok else 'FAIL'} ({report['mode']}): "
        f"similarity {report['transform']['is_similarity']}, "
        f"outside-affine {report['outside']['exact']}"
        + (f" (exact per cell: {exact['outside_mismatch']} mismatches)" if exact else "") + ", "
        f"peaks at cap {report['zones']['peaks_at_cap']}/{len(massifs)}, "
        f"masks {report['zones']['cells_match']}/{len(massifs)}, "
        f"in-zone values off the LUT {report['zones']['values_outside_lut_image']}, "
        f"worst slope error {report['no_crease']['worst_abs_error']}")

    if args.fig:
        make_figure(exp, inzone, massifs, shift, report, args.fig, log)
        report["figure"] = os.path.abspath(args.fig)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=1, sort_keys=True)
        log(f"wrote {args.json}")
    return 0 if ok else 1


def make_figure(exp, inzone, massifs, shift, report, path, log):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    step = 8
    small = exp[::step, ::step]
    zmask = inzone[::step, ::step]
    fig = plt.figure(figsize=(17, 8.6), dpi=110)

    ax = fig.add_subplot(1, 2, 1)
    ax.imshow(small, cmap="gist_earth", interpolation="nearest")
    ov = np.zeros(small.shape + (4,), dtype=np.float32)
    ov[zmask] = (1.0, 0.15, 0.15, 0.85)
    ax.imshow(ov, interpolation="nearest")
    ax.set_xticks([]); ax.set_yticks([])
    z = report["zones"]
    ax.set_title(f"IN-GAME expanded surface height {exp.shape[1]}x{exp.shape[0]} (1/{step})\n"
                 f"{z['massifs']} compression massifs in red ({z['pct_of_map']:.3f}% of the "
                 f"map), {z['peaks_at_cap']}/{z['massifs']} peaks exactly on {CAP}")

    ax2 = fig.add_subplot(2, 2, 2)
    for m in massifs:
        hs = np.arange(m["base"], m["peak"] + 1)
        ax2.plot(hs, lut_for(m["base"], m["peak"], m["base_img"], m["k"], shift), lw=0.8)
    ax2.axhline(CAP, lw=0.8, color="k")
    ax2.set_xlabel("resampled vanilla height (source units)")
    ax2.set_ylabel("expanded height")
    ax2.set_title(f"the {len(massifs)} stamped massif remaps: base tangent to the 4/3 affine, "
                  f"peak on the cap")
    ax2.grid(alpha=0.3)

    ax3 = fig.add_subplot(2, 2, 4)
    o, r, e = report["outside"], report["resample_residual"], report.get("exact")
    detail = (f"   residual vs the resample model: mean {r['mean_abs']}, max {r['max_abs']}\n"
              if r else "")
    if e:
        detail += (f"   EXACT per cell vs max(0, floor(min(pre, src_cap)*4/3) + shift):\n"
                   f"      {e['outside_mismatch']} mismatches, "
                   f"{e['pre_above_src_cap_outside']} pre values above src_cap\n")
    txt = (f"GATE {'PASS' if report['gate_ok'] else 'FAIL'} ({report.get('mode', 'heuristic')})\n\n"
           f"Z scale {report['transform']['zmul']}/{report['transform']['zdiv']} "
           f"(4/3 similarity: {report['transform']['is_similarity']})   "
           f"shift {report['transform']['shift']}\n"
           f"src_cap {report['transform']['src_cap']}   "
           f"final max {report['final']['grid_max']}   "
           f"cells at cap {report['final']['cells_at_cap']}\n\n"
           f"outside zones: {o['cells']:,} cells\n"
           f"   {o['impossible_affine_values']} values the 4/3 affine cannot produce\n"
           f"   {o['above_affine_of_src_cap']} above the affine image of src_cap\n"
           + detail +
           f"\ninside zones: {report['zones']['zone_cells']:,} cells\n"
           f"   {report['zones']['values_outside_lut_image']} values off their massif's LUT"
           + (f" ({e['inzone_lut_mismatch']} exact mismatches)" if e else "") + "\n"
           f"   masks match the stamp: "
           f"{report['zones']['cells_match']}/{report['zones']['massifs']}\n\n"
           f"no crease: worst |slope at base - 4/3| = "
           f"{report['no_crease']['worst_abs_error']}")
    ax3.axis("off")
    ax3.text(0.02, 0.98, txt, va="top", ha="left", fontsize=11, family="monospace")

    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)
    log(f"wrote {path}")


if __name__ == "__main__":
    sys.exit(main())
