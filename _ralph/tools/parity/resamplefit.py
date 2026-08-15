"""C2 - identify the XY RESAMPLE: is the expanded height grid the exact similarity of vanilla?

WHY
===
The `height-similarity-outside-zones` gate proves the Z transform exact, but it scores the
transform's OWN input against its OWN output (the `stretchdump` seam).  The transform's input is
already the XY-resampled grid, so the RESAMPLE step - `GridResample`, 6144 -> 8192 - has never
been scored against vanilla at all.  The whole terrain-only passability residual lives at the
one-cell scale, which is exactly where a resample acts, and the measured passability threshold
is only 26.25 wu per 100 wu, so a per-node resample error of a few wu is already threshold-sized.

WHAT IT MEASURES
================
Predict every sampled expanded node from the VANILLA grid under a family of resample models -
kernel (nearest / bilinear / box average of width w source cells) x alignment shift s, where the
model reads the source at (X*div/mul + s, Y*div/mul + s) - then applies the map's own stamped
affine.  Report the error distribution per model, robustly (median |err|), and the best fit.

  best |err| ~ 0                -> the expanded grid IS the exact similarity; the residual can
                                   only come from the LATTICE (75 source wu between expanded
                                   nodes vs 100 on vanilla), which is forced.
  best fit needs a shift        -> the transform misaligns the terrain: a real, fixable defect.
  best fit needs a wide kernel  -> the engine's resample SMOOTHS, which lowers one-cell slope
                                   maxima - inherently one-way false->true, and the mechanism
                                   the ruling demands be named.

The untouched UNDERGROUND is the control: it runs the same resample with no Z compression, so
any model that fits the surface must fit it too.

Usage:
  python resamplefit.py <vanilla_tag> <expanded_tag> <zones_txt> <out_json>
                                 [--stride 7] [--env surface]
"""
import json
import math
import sys
from pathlib import Path

import numpy as np

import zverdict             

OUT = Path(__file__).resolve().parent / "out"


def load_grid(path):
    raw = np.fromfile(path, dtype="<u2")
    side = int(round(math.sqrt(raw.size)))
    return raw.reshape((side, side)).astype(np.float64)      # [y, x]


def bilinear(g, fx, fy):
    ix = np.clip(np.floor(fx).astype(np.int64), 0, g.shape[1] - 2)
    iy = np.clip(np.floor(fy).astype(np.int64), 0, g.shape[0] - 2)
    tx, ty = fx - ix, fy - iy
    return ((1 - tx) * (1 - ty) * g[iy, ix] + tx * (1 - ty) * g[iy, ix + 1]
            + (1 - tx) * ty * g[iy + 1, ix] + tx * ty * g[iy + 1, ix + 1])


def box(g, fx, fy, w, n=4):
    """Average of the bilinear field over a w x w source-cell box centred on (fx, fy)."""
    offs = (np.arange(n) + 0.5) / n - 0.5
    acc = np.zeros_like(fx)
    for dy in offs:
        for dx in offs:
            acc += bilinear(g, fx + dx * w, fy + dy * w)
    return acc / (n * n)


def err_stats(err):
    a = np.abs(err)
    return {"n": int(err.size), "mean": round(float(err.mean()), 4),
            "median_abs": float(np.median(a)),
            "abs_le_1_pct": round(100.0 * float((a <= 1).mean()), 3),
            "abs_le_2_pct": round(100.0 * float((a <= 2).mean()), 3),
            "abs_le_8_pct": round(100.0 * float((a <= 8).mean()), 3),
            "abs_p99": float(np.percentile(a, 99)), "abs_max": int(a.max())}


def run_env(env, vtag, etag, stamp, stride):
    vg = load_grid(OUT / f"height-{vtag}-{env}.raw")
    eg = load_grid(OUT / f"height-{etag}-{env}.raw")
    st = (stamp.get(env) or {})
    mul, div, add = int(st["mul"]), int(st["div"]), int(st["add"])
    r = div / mul                                     # 0.75

    ys = np.arange(8, eg.shape[0] - 8, stride)
    xs = np.arange(8, eg.shape[1] - 8, stride)
    X, Y = np.meshgrid(xs, ys)
    X = X.ravel().astype(np.float64)
    Y = Y.ravel().astype(np.float64)
    obs = eg[Y.astype(np.int64), X.astype(np.int64)]
    fx0, fy0 = X * r, Y * r

    def score(v):
        return err_stats(obs - (np.floor(v * mul / div) + add))

    out = {"env": env, "affine": {"mul": mul, "div": div, "add": add},
           "stride": stride, "samples": int(obs.size), "shift_sweep": {}, "kernels": {}}

    best = None
    for s in np.arange(-1.0, 1.001, 0.125):
        rec = score(bilinear(vg, fx0 + s, fy0 + s))
        out["shift_sweep"][f"{s:+.3f}"] = {"median_abs": rec["median_abs"],
                                           "abs_le_1_pct": rec["abs_le_1_pct"]}
        if best is None or rec["median_abs"] < best[1]["median_abs"]:
            best = (float(s), rec)
    out["best_bilinear_shift"] = {"shift_source_cells": best[0], **best[1]}

    s = best[0]
    out["kernels"]["nearest"] = score(vg[np.clip(np.rint(fy0 + s).astype(np.int64), 0,
                                                 vg.shape[0] - 1),
                                         np.clip(np.rint(fx0 + s).astype(np.int64), 0,
                                                 vg.shape[1] - 1)])
    out["kernels"]["bilinear"] = score(bilinear(vg, fx0 + s, fy0 + s))
    for w in (0.75, 1.0, 1.333):
        out["kernels"][f"box_{w}"] = score(box(vg, fx0 + s, fy0 + s, w))

    # Does the expanded grid SMOOTH?  Compare the two grids' own one-cell slope statistics,
    # normalized to wu per 100 wu of their own map (the engine's units), over the same region.
    def stat(g):
        dv = np.abs(np.diff(g, axis=0))
        dh = np.abs(np.diff(g, axis=1))
        return np.maximum(np.maximum(dv[:, :-1], dv[:, 1:]), np.maximum(dh[:-1, :], dh[1:, :]))

    vs = stat(vg)[8:-8:stride, 8:-8:stride].ravel()
    es = stat(eg)[8:-8:stride, 8:-8:stride].ravel()
    out["slope_statistic"] = {
        "vanilla": {"mean": round(float(vs.mean()), 3), "median": float(np.median(vs)),
                    "p90": float(np.percentile(vs, 90)), "ge_26_25_pct":
                    round(100.0 * float((vs >= 26.25).mean()), 4)},
        "expanded": {"mean": round(float(es.mean()), 3), "median": float(np.median(es)),
                     "p90": float(np.percentile(es, 90)), "ge_26_25_pct":
                     round(100.0 * float((es >= 26.25).mean()), 4)},
        "note": "same normalization (wu per 100 wu of own map); a lower expanded distribution "
                "means the resample smooths one-cell slope maxima",
    }
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a.split("=", 1)[0]: (a.split("=", 1)[1] if "=" in a else True)
             for a in sys.argv[1:] if a.startswith("--")}
    if len(args) < 4:
        raise SystemExit(__doc__)
    vtag, etag, zones_txt, out_json = args[:4]
    stride = int(flags.get("--stride", 7))
    only = flags.get("--env")
    stamp = zverdict.read_stamp(zones_txt)
    res = {"vanilla": vtag, "expanded": etag, "zones": zones_txt, "maps": {}}
    for env in ("underground", "surface"):
        if only and only is not True and env != only:
            continue
        if not (OUT / f"height-{vtag}-{env}.raw").exists():
            continue
        res["maps"][env] = run_env(env, vtag, etag, stamp, stride)
    Path(out_json).write_text(json.dumps(res, indent=2), encoding="utf-8")
    print(json.dumps(res, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
