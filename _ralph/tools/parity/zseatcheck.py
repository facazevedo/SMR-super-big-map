"""Object SEATING verdict for the `floors` gate note: does object Z follow the new transform?

WHY THIS EXISTS
===============
The task contract's `floors` NOTE says this change ALTERS every surface Z, so "object-Z
verdicts must follow the new transform (exact affine outside zones, SetTerrainZ inside),
and that update must be justified in the gate code, never a silent tolerance".

`zverdict.py` states half of it: the residual of the object's ABSOLUTE Z against the
affine image of its vanilla twin's Z, reported as a distribution because per-object
exactness never was a property of this pipeline (the dumped Z is an INTERPOLATION between
height-grid nodes and resampling does not commute with interpolation).  That statistic
cannot decide the second half at all: inside a massif the affine is invalid BY DESIGN, so
a large residual there is expected and a small one proves nothing.

This tool scores the property that IS well posed on both sides of the zone boundary:

    HAT (height above terrain) = object z - terrain height under the object's own position

measured on each twin against THAT twin's own dumped height grid.  A similarity transform
scales every vertical length by the same factor, so outside the massifs the requirement is

    HAT_expanded == (4/3) * HAT_vanilla                                     (exact affine)

for every object, whatever its class-specific sink/lift offset - and that is a strictly
stronger statement than "the ground is the affine image", which the height gate already
proves cell-exact.  Inside a massif the ground is NOT the affine image, so an object that
seats by SetTerrainZ keeps its HAT on the COMPRESSED ground:

    HAT_expanded == (4/3) * HAT_vanilla  still holds  <=>  the object followed the ground
    down with the massif, i.e. it was seated from the real final terrain and not stamped
    with the (invalid) affine Z.

The discriminator is therefore the pair (affine residual, HAT residual) on the cells whose
GROUND was actually compressed:

    affine residual LARGE + HAT residual SMALL -> seated by SetTerrainZ  (the contract's
                                                  step 7, what this gate wants);
    affine residual SMALL + HAT residual LARGE -> stamped with the affine and now floating
                                                  above / buried under the compressed ground.

"Ground compressed" is measured per object, not from zone geometry: it is
affine(h_vanilla) - h_expanded under the object's own position, so it needs no massif mask
and cannot be widened by a bbox.  The massif bboxes from the run's Z stamp are reported as
a second, categorical split (a crop bbox is a SUPERSET of its massif, so `in_bbox`
over-counts, never the other way round).

Two populations are reported apart and never mixed into the verdict:
  * the entrance/passage family, which holds the contract's ONE positional exemption - its
    objects legitimately stand somewhere else on the expanded map, so their ground is a
    different piece of ground and neither residual is meaningful;
  * rows without a dumped Z on either twin, and the engine `CameraObj` (not a map object).

TOLERANCE AND CONTROL, STATED
=============================
No tolerance is applied to any verdict count: the full |HAT residual| distribution is
reported and read against two measured quantities from the SAME run, never against a
constant picked here.

  * SCALE - `hat_vanilla` / `hat_expanded`, the distribution of the HATs themselves.  A
    residual of ~1 wu is meaningful only next to objects whose own HAT runs to hundreds or
    thousands of wu (rocks and cliffs are deliberately sunk into the ground).
  * CONTROL - `control_affine_stamped_seating`, the counterfactual residual this statistic
    WOULD have reported had each object kept the stamped affine Z instead of being seated
    from the final terrain.  Substituting z_expanded := affine(z_vanilla) makes the residual
    collapse to the local ground compression, so this control is computed, not asserted, and
    it is what separates "seated on the real compressed ground" from "stamped and floating".
    On ground the transform did not compress it is ~0 by construction, i.e. the statistic
    genuinely cannot discriminate there, and it says so.

`ground_compressed` is itself calibrated by the UNDERGROUND, whose transform is a uniform
4/3 with no massifs at all: whatever crosses the threshold there is resample/interpolation
noise, and it bounds the split's own false-positive rate on the same run.

Usage:
  python zseatcheck.py <vanilla_tag> <expanded_tag> <zones_txt> <out_json>
"""
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import compare  # noqa: E402
import zverdict  # noqa: E402

OUT = HERE / "out"
TILE = 100                 # const.HeightTileSize: world units per height-grid tile
COMPRESSED_WU = 100        # ground counts as compressed when the affine over-predicts by
                           # more than one in-game metre (guim = 1000 wu -> 0.1 m); a
                           # threshold ONLY for the diagnostic split, never for a verdict
TOP_N = 12
SKIP_CLASSES = {"CameraObj"}   # engine camera helper: not a map object, z is the camera pose


def load_grid(tag, side):
    path = OUT / f"height-{tag}-{side}.raw"
    if not path.exists():
        return None
    raw = np.fromfile(path, dtype="<u2")
    n = int(round(math.sqrt(len(raw))))
    if n * n != len(raw):
        raise SystemExit(f"{path}: {len(raw)} samples is not a square grid")
    return raw.reshape((n, n))


def bilinear(g, xs, ys):
    """Terrain height under continuous world positions, bilinear over the height grid."""
    n = g.shape[0]
    fx, fy = xs / TILE, ys / TILE
    x0 = np.clip(np.floor(fx).astype(np.int64), 0, n - 1)
    y0 = np.clip(np.floor(fy).astype(np.int64), 0, n - 1)
    x1, y1 = np.clip(x0 + 1, 0, n - 1), np.clip(y0 + 1, 0, n - 1)
    tx, ty = np.clip(fx - x0, 0.0, 1.0), np.clip(fy - y0, 0.0, 1.0)
    return (g[y0, x0] * (1 - tx) * (1 - ty) + g[y0, x1] * tx * (1 - ty)
            + g[y1, x0] * (1 - tx) * ty + g[y1, x1] * tx * ty)


def pct(a, p):
    return float(np.percentile(a, p)) if len(a) else None


def stats(a):
    a = np.asarray(a, dtype=np.float64)
    return {"n": int(a.size), "exact": int((a == 0).sum()) if a.size else 0,
            "p50": pct(np.abs(a), 50), "p90": pct(np.abs(a), 90),
            "p99": pct(np.abs(a), 99),
            "max": float(np.abs(a).max()) if a.size else None,
            "mean_signed": float(a.mean()) if a.size else None}


def pair_rows(vrows, erows):
    """Same pairing as zverdict: class + stamped SOURCE position, one-to-one."""
    pool = defaultdict(list)
    for r in vrows:
        if r["x"] is not None:
            pool[(r["class"], r["x"], r["y"])].append(r)
    pairs, unpaired = [], 0
    for r in erows:
        if r["src_x"] is None or r["x"] is None:
            continue
        bucket = pool.get((r["src_class"] or r["class"], r["src_x"], r["src_y"]))
        if bucket:
            pairs.append((bucket.pop(), r))
        else:
            unpaired += 1
    return pairs, unpaired


def score_map(vrows, erows, vg, eg, st):
    ratio = st["mul"] / st["div"]
    pairs, unpaired = pair_rows(vrows, erows)
    keep, entrance, no_z, skipped = [], [], 0, 0
    for v, e in pairs:
        if v["class"] in SKIP_CLASSES or e["class"] in SKIP_CLASSES:
            skipped += 1
            continue
        if v["z"] is None or e["z"] is None or compare.INVALID_Z in (v["z"], e["z"]):
            no_z += 1
            continue
        (entrance if compare.is_entrance_family(e["class"]) else keep).append((v, e))

    def measure(sel):
        if not sel:
            return None
        vx = np.array([v["x"] for v, _ in sel], dtype=np.float64)
        vy = np.array([v["y"] for v, _ in sel], dtype=np.float64)
        vz = np.array([v["z"] for v, _ in sel], dtype=np.float64)
        ex = np.array([e["x"] for _, e in sel], dtype=np.float64)
        ey = np.array([e["y"] for _, e in sel], dtype=np.float64)
        ez = np.array([e["z"] for _, e in sel], dtype=np.float64)
        hv, he = bilinear(vg, vx, vy), bilinear(eg, ex, ey)
        return {
            "v": sel, "vz": vz, "ez": ez, "ex": ex, "ey": ey,
            "hat_v": vz - hv, "hat_e": ez - he,
            "hat_res": (ez - he) - ratio * (vz - hv),
            "affine_res": ez - (np.floor(vz * st["mul"] / st["div"]) + st["add"]),
            "ground_comp": (np.floor(hv * st["mul"] / st["div"]) + st["add"]) - he,
        }

    m = measure(keep)
    if m is None:
        return {"paired": len(pairs), "scored": 0, "no_z": no_z, "unpaired": unpaired}

    cx = (m["ex"] / TILE).astype(np.int64)
    cy = (m["ey"] / TILE).astype(np.int64)
    in_bbox = np.zeros(len(cx), dtype=bool)
    for x0, y0, x1, y1 in st["massifs"]:
        in_bbox |= (cx >= x0) & (cx <= x1) & (cy >= y0) & (cy <= y1)
    compressed = m["ground_comp"] > COMPRESSED_WU

    groups = {
        "outside_bbox": ~in_bbox,
        "in_bbox": in_bbox,
        "ground_compressed": compressed,
        "ground_uncompressed": ~compressed,
    }
    out = {
        "z_stamp": {k: st[k] for k in ("mul", "div", "add", "uniform")},
        "massifs": len(st["massifs"]),
        "paired": len(pairs), "scored": len(keep), "no_z": no_z,
        "unpaired": unpaired, "skipped_classes": skipped,
        "entrance_family_excluded": len(entrance),
        "compressed_threshold_wu": COMPRESSED_WU,
        "ground_compression_max": float(m["ground_comp"].max()),
        "groups": {},
    }
    # The discriminating cell: ground actually compressed AND inside a massif bbox.
    groups["compressed_in_bbox"] = compressed & in_bbox
    # Counterfactual control: the same statistic recomputed with the object stamped at the
    # affine Z instead of seated from the final terrain (z := affine(z_vanilla)).
    control = (np.floor(m["vz"] * st["mul"] / st["div"]) + st["add"]) - (
        m["ez"] - m["hat_e"]) - ratio * m["hat_v"]
    for name, sel in groups.items():
        out["groups"][name] = {
            "hat_residual": stats(m["hat_res"][sel]),
            "affine_residual": stats(m["affine_res"][sel]),
            "ground_compression": stats(m["ground_comp"][sel]),
            "control_affine_stamped_seating": stats(control[sel]),
        }
    # SCALE: the HATs themselves, so a residual is read against the lengths it measures.
    out["hat_vanilla"] = stats(m["hat_v"])
    out["hat_expanded"] = stats(m["hat_e"])

    order = np.argsort(-np.abs(m["hat_res"]))[:TOP_N]
    out["top_hat_residual"] = [{
        "class": keep[i][1]["class"],
        "expanded_xy": [int(m["ex"][i]), int(m["ey"][i])],
        "hat_vanilla": float(m["hat_v"][i]), "hat_expanded": float(m["hat_e"][i]),
        "hat_residual": float(m["hat_res"][i]),
        "affine_residual": float(m["affine_res"][i]),
        "ground_compression": float(m["ground_comp"][i]),
        "in_bbox": bool(in_bbox[i]),
    } for i in order]
    per = defaultdict(list)
    for i, (_, e) in enumerate(keep):
        per[e["class"]].append(abs(float(m["hat_res"][i])))
    out["worst_classes"] = sorted(
        ({"class": c, "n": len(d), "p50": float(np.percentile(d, 50)),
          "max": float(max(d))} for c, d in per.items()),
        key=lambda r: -r["max"])[:8]
    if entrance:
        me = measure(entrance)
        out["entrance_family"] = {
            "n": len(entrance),
            "classes": sorted({e["class"] for _, e in entrance}),
            "hat_residual": stats(me["hat_res"]),
            "affine_residual": stats(me["affine_res"]),
            "note": "contract exemption 1 (position): reported, never scored",
        }
    return out


def main():
    vtag, etag, zones_txt, out_json = sys.argv[1:5]
    _vmeta, vrows, _a, _b = compare.parse_dump(OUT / f"objects-{vtag}.csv")
    emeta, erows, _c, _d = compare.parse_dump(OUT / f"objects-{etag}.csv")
    stamp = zverdict.meta_stamp(emeta) if zones_txt == "-" else zverdict.read_stamp(zones_txt)

    result = {"vanilla": vtag, "expanded": etag, "zones": zones_txt, "maps": {}}
    for m in ("surface", "underground"):
        vg, eg = load_grid(vtag, m), load_grid(etag, m)
        if m not in stamp or vg is None or eg is None:
            continue
        result["maps"][m] = score_map(vrows[m], erows[m], vg, eg, stamp[m])
    Path(out_json).write_text(json.dumps(result, indent=2), encoding="utf-8")

    for m, v in result["maps"].items():
        print(f"[{m}] affine {v['z_stamp']['mul']}/{v['z_stamp']['div']}"
              f"+{v['z_stamp']['add']} massifs={v['massifs']} scored={v['scored']} "
              f"entrance_excluded={v['entrance_family_excluded']}")
        for name, g in v["groups"].items():
            h, a, c = (g["hat_residual"], g["affine_residual"],
                       g["control_affine_stamped_seating"])
            if not h["n"]:
                continue
            print(f"   {name:<20} n={h['n']:<6} HAT |d| p50={h['p50']:<8.2f} "
                  f"p90={h['p90']:<9.2f} max={h['max']:<12.2f} "
                  f"| affine |d| p50={a['p50']:<8.1f} max={a['max']:<10.1f} "
                  f"| control max={c['max']:.1f}")
        for t in v["top_hat_residual"][:4]:
            print(f"     TOP hat_res={t['hat_residual']:<10.2f} {t['class'][:26]:<26} "
                  f"hat_v={t['hat_vanilla']:<9.1f} hat_e={t['hat_expanded']:<9.1f} "
                  f"gcomp={t['ground_compression']:.0f} in_bbox={t['in_bbox']}")
    print("->", out_json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
