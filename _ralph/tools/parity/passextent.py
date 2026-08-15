"""C3 - is the object-free residual an artefact of excluding objects by POSITION?

WHY THIS EXISTS
===============
`passlattice_probe.lua` keeps a lattice sample only when its distance to the nearest object
POSITION exceeds 2400 source wu, and the ruling's own wording calls that threshold "a safe
first cut" for "the largest object footprint".  A position is not an extent: an object whose
own geometry reaches further than 2400 wu still obstructs ground the probe calls object-free,
so every object-free number measured so far (surface 1,121 of 79,647 at 45S82E, 1,631 of
89,254 at the held-out 42S28W) could in principle carry an obstruction term rather than being
pure terrain.  C2's lattice-forced explanation is only about terrain, so this has to be
excluded before that explanation can be presented as complete.

WHAT IT DOES
============
The probe's `dmin_src` column is CAPPED at its 4800 wu bucket, so the on-disk lattice cannot
answer "what happens further out" by itself.  This tool recomputes the exact distance from
every scored sample to the nearest object on BOTH twins, without a cap, from the same run's
`pass-*.csv` object dumps (the same object set the lattice probe bucketed - `map:MapGet("map")`
read through `GetVisualPosXYZ`), in SOURCE units, and then re-scores the twin comparison under
three exclusion rules:

  sweep        plain distance-to-position exclusion at radii from the gate's 2400 out to
               24000 source wu (240 m - two orders past any entity's own size);
  bins         the diff RATE inside distance shells, which is the shape that decides it: any
               obstruction term must DECAY with distance from the objects, while a terrain
               term is flat;
  extent       distance to the object's measured obstruction radius rather than to its
               position.  Extents are not in any dump, so they are MEASURED from the vanilla
               twin's own ring columns: `pass_probe.lua` samples 8 compass points at 600/1200/
               2400 source wu around every object, and a class whose objects block the
               majority of those points at radius r really does obstruct out to r.  The
               exclusion then asks for 2400 wu of clearance beyond that radius.  This proxy
               has a known upward bias: an object standing ON impassable ground blocks every
               bearing whatever its own size, so a class of markers in rough terrain scores a
               large extent.  It can therefore only over-exclude, which is the safe direction.

DISTANCE IS NOT AN INDEPENDENT VARIABLE, so the shells alone cannot answer it: objects are
placed on and around rough ground (rocks live at cliffs), so a far shell is also a FLATTER
shell, and the residual only exists near the slope threshold.  Every shell is therefore
re-scored CONDITIONED on the vanilla slope statistic Sv from `latticeforce.py`'s npz dump
(same pairing, same order) - both restricted to the near-threshold band |Sv - T| <= 5 where
the residual lives, and reported with each shell's own mean Sv so the confound is visible
rather than assumed away.

INTERPRETATION, fixed before the run
====================================
  (a) the CONDITIONED diff rate is flat in distance  ->  the residual is not object
      obstruction; it is terrain, and C2's lattice-forced explanation stands as the whole
      story.
  (b) the conditioned rate DECAYS with distance  ->  part of the object-free residual is
      obstruction after all; the object-free numbers must be re-derived at the larger radius
      before any gate wording rests on them.

Usage:
  python passextent.py <vanilla_tag> <expanded_tag> <zones_txt> <out_json>
                       [--threshold=2400] [--env=surface] [--dump-dir=DIR]
                       [--stat-npz-dir=DIR] [--slope-threshold=27] [--near-band=5]
"""
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree

import passlatticecheck as P
import passcelldiag as D
import passverdict as V
import zverdict

OUT = Path(__file__).resolve().parent / "out"
TILE = 100
SWEEP = (2400, 3000, 3600, 4800, 6000, 8000, 12000, 16000, 24000)
BINS = (2400, 3600, 4800, 7200, 12000, 24000, 10 ** 9)
RING_RADII = (600, 1200, 2400)          # pass_probe.lua's own ring radii, SOURCE wu
RING_MAJORITY = 0.5                     # a class obstructs at r when it blocks most bearings


def measured_extents(vrows):
    """Per-class obstruction radius, measured from the vanilla twin's own ring samples.

    `pass_probe.lua` reports, per object, how many of 8 compass points at each ring radius are
    impassable.  Terrain alone blocks some of them, so a single object proves nothing; a CLASS
    whose objects block the majority of bearings at radius r is obstructing out to r.  The
    radius is therefore the largest ring whose class-mean blocked fraction reaches the
    majority.  Reported so the exclusion can be read as a measurement, not a guess.
    """
    acc = defaultdict(lambda: [0] + [0] * len(RING_RADII))
    for r in vrows:
        a = acc[r["class"]]
        a[0] += 1
        for i, rad in enumerate(RING_RADII):
            v = r.get(f"r{rad}")
            if isinstance(v, int):
                a[1 + i] += v
    ext, table = {}, []
    for cls, a in acc.items():
        n = a[0]
        fracs = [a[1 + i] / (8.0 * n) for i in range(len(RING_RADII))]
        radius = 0
        for i, rad in enumerate(RING_RADII):
            if fracs[i] >= RING_MAJORITY:
                radius = rad
        ext[cls] = radius
        table.append({"class": cls, "n": n, "extent_src_wu": radius,
                      "blocked_frac": [round(f, 3) for f in fracs]})
    table.sort(key=lambda e: (-e["extent_src_wu"], -e["n"]))
    return ext, table


def object_xy(rows, scale):
    """Object positions of one twin in SOURCE units, from its own pass dump."""
    xs = np.array([r["x"] for r in rows], dtype=np.float64) / scale
    ys = np.array([r["y"] for r in rows], dtype=np.float64) / scale
    return np.stack([xs, ys], axis=1)


def nearest(pts, objs):
    if objs.shape[0] == 0:
        return np.full(pts.shape[0], np.inf)
    return cKDTree(objs).query(pts, k=1)[0]


def nearest_minus_extent(pts, objs, classes, extents):
    """min over objects of (distance - that object's class extent), in source units."""
    best = np.full(pts.shape[0], np.inf)
    by_r = defaultdict(list)
    for i, c in enumerate(classes):
        by_r[extents.get(c, 0)].append(i)
    for radius, idx in by_r.items():
        d = nearest(pts, objs[np.array(idx, dtype=np.int64)])
        best = np.minimum(best, d - radius)
    return best


def counts(diff, f2t_mask, keep):
    n = int(keep.sum())
    d = int((diff & keep).sum())
    f = int((diff & keep & f2t_mask).sum())
    return {"scored": n, "diff": d, "false_to_true": f, "true_to_false": d - f,
            "diff_rate_pct": round(100.0 * d / n, 4) if n else None,
            "bias_ratio": round(f / (d - f), 3) if d - f else (None if not f else float("inf"))}


def poisson_band(rate_pct, n):
    """+-1 sigma on a rate of independent events, in percentage points."""
    if not n or rate_pct is None:
        return None
    k = rate_pct * n / 100.0
    return round(100.0 * math.sqrt(max(k, 1.0)) / n, 4)


def spearman(x, y):
    def rank(a):
        order = np.argsort(a, kind="mergesort")
        r = np.empty(a.size, dtype=np.float64)
        r[order] = np.arange(1, a.size + 1, dtype=np.float64)
        # average ties
        s = a[order]
        i = 0
        while i < s.size:
            j = i
            while j + 1 < s.size and s[j + 1] == s[i]:
                j += 1
            if j > i:
                r[order[i:j + 1]] = (i + j) / 2.0 + 1.0
            i = j + 1
        return r
    rx, ry = rank(x), rank(y)
    rx -= rx.mean()
    ry -= ry.mean()
    den = math.sqrt(float((rx ** 2).sum()) * float((ry ** 2).sum()))
    return round(float((rx * ry).sum()) / den, 4) if den else None


def load_stat(stat_dir, env, vtag, etag, n):
    """Sv per scored pair from `latticeforce.py`'s npz - same pairing, same order.

    latticeforce drops any pair whose height-grid cell falls outside the grid, so the arrays
    are accepted only when their length still matches this tool's pair count; a mismatch is
    reported instead of silently joining two different sets.
    """
    if not stat_dir:
        return None, "not requested"
    p = Path(stat_dir) / f"latticeforce-{env}-{vtag}-{etag}.npz"
    if not p.exists():
        return None, f"missing {p.name}"
    z = np.load(p)
    if z["Sv"].size != n:
        return None, f"length {z['Sv'].size} != pairs {n}"
    return z["Sv"].astype(np.float64), str(p)


def run_env(env, vtag, etag, stamp, threshold, dump_dir, stat_dir, T, band):
    vrows, vmeta = P.read_lattice(OUT / f"passlat-{vtag}.csv")
    erows, emeta = P.read_lattice(OUT / f"passlat-{etag}.csv")
    if not vrows.get(env) or not erows.get(env):
        return None
    massifs = (stamp.get(env) or {}).get("massifs", [])
    pairs = D.pair_samples(vrows[env], erows[env], massifs, threshold)
    if not pairs:
        return None

    # Sample position in SOURCE units: the vanilla twin runs at scale 1.
    pts = np.array([[v["x"], v["y"]] for v, _ in pairs], dtype=np.float64)
    pv = np.array([v["p"] for v, _ in pairs], dtype=np.int64)
    pe = np.array([e["p"] for _, e in pairs], dtype=np.int64)
    diff = pv != pe
    f2t_mask = pv == 0

    vobj = [r for r in V.read_pass(OUT / f"pass-{vtag}.csv") if r["map"] == env]
    eobj = [r for r in V.read_pass(OUT / f"pass-{etag}.csv") if r["map"] == env]
    escale = float(emeta[env].get("grid", "8192x8192").split("x")[0]) / float(
        vmeta[env].get("grid", "6144x6144").split("x")[0])
    vxy = object_xy(vobj, 1.0)
    exy = object_xy(eobj, escale)

    dv = nearest(pts, vxy)
    de = nearest(pts, exy)
    dmin = np.minimum(dv, de)

    # Cross-check against the probe's own capped column: below the 4800 bucket cap the two
    # must agree, or the recomputation is measuring a different object set.
    probe_d = np.array([min(v["dmin_src"], e["dmin_src"]) for v, e in pairs], dtype=np.float64)
    below = probe_d < 4790
    agree = float(np.abs(probe_d - dmin)[below].max()) if below.any() else None

    extents, ext_table = measured_extents(vobj)
    dvx = nearest_minus_extent(pts, vxy, [r["class"] for r in vobj], extents)
    dex = nearest_minus_extent(pts, exy, [r["class"] for r in eobj], extents)
    dext = np.minimum(dvx, dex)

    out = {
        "env": env, "massifs": len(massifs), "pairs": int(pts.shape[0]),
        "expanded_scale": round(escale, 6),
        "objects": {"vanilla": len(vobj), "expanded": len(eobj)},
        "recomputed_vs_probe_dmin_max_abs_below_cap": agree,
        "baseline_at_threshold": counts(diff, f2t_mask, dmin >= threshold),
        "sweep_by_distance_to_position": {
            str(r): counts(diff, f2t_mask, dmin >= r) for r in SWEEP},
        "shells_by_distance_to_position": {},
        "extent_rule": {
            "classes_with_extent": {str(r): sum(1 for c, v in extents.items() if v == r)
                                    for r in (0,) + RING_RADII},
            "objects_with_extent": {
                str(r): sum(1 for o in vobj if extents.get(o["class"], 0) == r)
                for r in (0,) + RING_RADII},
            "scored": counts(diff, f2t_mask, dext >= threshold),
            "largest_extent_src_wu": max(extents.values()) if extents else 0,
        },
        "extent_class_table": ext_table[:15],
    }
    for lo, hi in zip(BINS[:-1], BINS[1:]):
        keep = (dmin >= lo) & (dmin < hi)
        c = counts(diff, f2t_mask, keep)
        c["poisson_sigma_pct"] = poisson_band(c["diff_rate_pct"], c["scored"])
        out["shells_by_distance_to_position"][f"{lo}-{hi if hi < 10 ** 9 else 'inf'}"] = c

    out["spearman_rho_distance_vs_diff"] = spearman(dmin, diff.astype(np.float64))

    # Raw shells first - but they confound distance with terrain, so they decide nothing.
    shells = [v for v in out["shells_by_distance_to_position"].values() if v["scored"] > 500]
    if len(shells) >= 2:
        near, far = shells[0], shells[-1]
        out["raw_near_shell_rate_pct"] = near["diff_rate_pct"]
        out["raw_far_shell_rate_pct"] = far["diff_rate_pct"]

    # The verdict: the same shells inside the near-threshold band, where the residual lives.
    Sv, src = load_stat(stat_dir, env, vtag, etag, int(pts.shape[0]))
    out["slope_statistic_source"] = src
    if Sv is not None:
        near_band = np.abs(Sv - T) <= band
        out["slope_threshold_wu_per_100wu"] = T
        out["near_threshold_band"] = band
        cond = {}
        for lo, hi in zip(BINS[:-1], BINS[1:]):
            keep = (dmin >= lo) & (dmin < hi)
            c = counts(diff, f2t_mask, keep & near_band)
            c["poisson_sigma_pct"] = poisson_band(c["diff_rate_pct"], c["scored"])
            c["mean_Sv_all"] = round(float(Sv[keep].mean()), 3) if keep.any() else None
            c["near_band_share_pct"] = (round(100.0 * float(near_band[keep].mean()), 3)
                                        if keep.any() else None)
            cond[f"{lo}-{hi if hi < 10 ** 9 else 'inf'}"] = c
        out["shells_conditioned_on_near_threshold"] = cond
        out["spearman_rho_distance_vs_diff_near_band"] = spearman(
            dmin[near_band], diff[near_band].astype(np.float64))
        # The same conditioning applied to the exclusion RULES: if a rule's raw rate moves only
        # because it selects different terrain, its conditioned rate does not move.
        out["sweep_conditioned"] = {str(r): counts(diff, f2t_mask, (dmin >= r) & near_band)
                                    for r in SWEEP}
        out["extent_rule"]["scored_conditioned"] = counts(diff, f2t_mask,
                                                          (dext >= threshold) & near_band)
        out["baseline_conditioned"] = counts(diff, f2t_mask, (dmin >= threshold) & near_band)

        usable = [v for v in cond.values() if v["scored"] > 300]
        if len(usable) >= 2:
            n0, f0 = usable[0], usable[-1]
            sigma = math.hypot(n0.get("poisson_sigma_pct") or 0.0,
                               f0.get("poisson_sigma_pct") or 0.0)
            drop = (n0["diff_rate_pct"] or 0.0) - (f0["diff_rate_pct"] or 0.0)
            out["conditioned_near_rate_pct"] = n0["diff_rate_pct"]
            out["conditioned_far_rate_pct"] = f0["diff_rate_pct"]
            out["conditioned_near_minus_far_pct_points"] = round(drop, 4)
            out["conditioned_decay_sigmas"] = round(drop / sigma, 2) if sigma else None
            out["obstruction_term_detected"] = bool(sigma and drop / sigma >= 3.0)

    if dump_dir:
        d = Path(dump_dir)
        d.mkdir(parents=True, exist_ok=True)
        np.savez_compressed(d / f"passextent-{env}-{vtag}-{etag}.npz",
                            dmin=dmin, dext=dext, pv=pv, pe=pe,
                            x=pts[:, 0], y=pts[:, 1])
        out["npz"] = str(d / f"passextent-{env}-{vtag}-{etag}.npz")
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a.split("=", 1)[0]: (a.split("=", 1)[1] if "=" in a else True)
             for a in sys.argv[1:] if a.startswith("--")}
    if len(args) < 4:
        raise SystemExit(__doc__)
    vtag, etag, zones_txt, out_json = args[:4]
    threshold = int(flags.get("--threshold", 2400))
    only = flags.get("--env")
    dump_dir = flags.get("--dump-dir")
    stat_dir = flags.get("--stat-npz-dir")
    T = float(flags.get("--slope-threshold", 27))
    band = float(flags.get("--near-band", 5))
    stamp = zverdict.read_stamp(zones_txt)

    res = {"vanilla": vtag, "expanded": etag, "zones": zones_txt,
           "threshold_src_wu": threshold, "maps": {}}
    for env in ("surface", "underground"):
        if only and only is not True and env != only:
            continue
        r = run_env(env, vtag, etag, stamp, threshold,
                    dump_dir if dump_dir is not True else None,
                    stat_dir if stat_dir is not True else None, T, band)
        if r:
            res["maps"][env] = r

    s = res["maps"].get("surface")
    res["obstruction_term_detected"] = bool(s and s.get("obstruction_term_detected"))
    res["interpretation"] = ("b_obstruction_term_present" if res["obstruction_term_detected"]
                             else "a_residual_is_terrain_not_obstruction")
    Path(out_json).write_text(json.dumps(res, indent=2), encoding="utf-8")
    print(json.dumps(res, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
