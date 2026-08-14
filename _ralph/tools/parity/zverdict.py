"""Object-Z verdict for the `floors` gate under the full-4/3 Z transform.

WHY THIS EXISTS (contract `full-z-parity`, `floors` note)
=========================================================
compare.py's 21-case object parity matches objects on class + stamped SOURCE position and
never on absolute Z, so it cannot see a wrong Z at all.  This task changes every surface Z,
so the object-Z verdict has to be stated explicitly and scored - never absorbed by a
tolerance.  This tool is that verdict.

WHAT THE VERDICT IS, AND WHY IT IS NOT "EVERY OBJECT ON THE AFFINE"
==================================================================
An object's dumped Z is the terrain height under a CONTINUOUS position, so it is an
INTERPOLATION between height-grid nodes.  The destination grid is the resample of the
source grid, and resampling does not commute with interpolation: a sub-cell residual of d
source units appears in the destination as z_ratio * d.  Measured on the pre-change v804
pipeline at 30S146E (`objects-w1a` vs `objects-w1x`, z ratio 1.0153): only 965 of 2213
z-carrying stamped surface objects sat exactly on the affine, p90 |d| = 8, max 649.  So
per-object exactness was NEVER a property of this pipeline and demanding it here would fail
the pre-change code too.

The verdict therefore reports the residual DISTRIBUTION, split by zone membership, and is
read against that same v804 baseline:

  * outside the compression massifs the residual must keep the baseline's SHAPE, scaled by
    the ratio of the two transforms ((4/3) / 1.0971 = 1.215 at 42S28W); a residual that
    grows by more than the transform is a seating defect, not resampler noise;
  * inside a massif the affine is invalid by construction (contract step 7: the ground is
    the compressed image and objects seat by SetTerrainZ), so those objects are counted and
    reported separately and never scored against the affine;
  * the top |residual| offenders are always listed with class and position, because a
    single flat CLUSTER of large residuals is the signature of ground that the transform
    did not reach (a later terrain edit writing source-space heights), which is exactly the
    failure per-object exactness would have hidden inside its noise floor.

Zone membership is scored on the destination height-grid cell (world / HeightTileSize)
against the massif crop bboxes in the run's own Z stamp.  A crop bbox is a SUPERSET of its
massif's component, so "inside" over-counts: the outside-zone set that carries the verdict
is conservative, never the other way round.

Usage:
  python zverdict.py <vanilla_tag> <expanded_tag> <zones_txt|-> <out_json>

`-` scores a run that predates the zone stamp (the v804 pipeline): the affine then comes
from the expanded dump's own `#meta` SuperBigMapZScale* keys and there are no massifs,
which is exactly that transform's own contract.  That is how the baseline above is made.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import compare  # noqa: E402

OUT = HERE / "out"
HEIGHT_TILE = 100  # const.HeightTileSize: world units per terrain tile
TOP_N = 12


def read_stamp(path):
    """Parse height_dump_probe.lua's stamp -> {map: {mul, div, add, massifs:[bbox]}}."""
    stamp = {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        f = line.split(",")
        if f[0] == "map":
            kv = dict(p.split("=", 1) for p in f[2:] if "=" in p)
            stamp[f[1]] = {"mul": int(kv["zmul"]), "div": int(kv["zdiv"]),
                           "add": int(kv["zadd"]), "uniform": kv.get("uniform"),
                           "massifs": []}
        elif f[0] == "massif":
            kv = dict(p.split("=", 1) for p in f[3:] if "=" in p)
            stamp[f[1]]["massifs"].append(
                (int(kv["x0"]), int(kv["y0"]), int(kv["x1"]), int(kv["y1"])))
    return stamp


def meta_stamp(emeta):
    stamp = {}
    for m in ("surface", "underground"):
        mul = emeta.get(m, {}).get("SuperBigMapZScaleMul")
        if mul in (None, "-"):
            continue
        stamp[m] = {"mul": int(mul), "div": int(emeta[m]["SuperBigMapZScaleDiv"]),
                    "add": int(emeta[m]["SuperBigMapZScaleAdd"]), "uniform": "meta",
                    "massifs": []}
    return stamp


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    return s[min(len(s) - 1, int(round((len(s) - 1) * p)))]


def score_map(vrows, erows, st):
    pool = defaultdict(list)
    for r in vrows:
        if r["x"] is not None:
            pool[(r["class"], r["x"], r["y"])].append(r)

    stamped = paired = no_z = unpaired = 0
    outside, inside, top = [], [], []
    per_class = defaultdict(list)
    for r in erows:
        if r["src_x"] is None or r["x"] is None:
            continue
        stamped += 1
        bucket = pool.get((r["src_class"] or r["class"], r["src_x"], r["src_y"]))
        if not bucket:
            unpaired += 1
            continue
        v = bucket.pop()
        paired += 1
        if v["z"] is None or r["z"] is None:
            no_z += 1
            continue
        d = r["z"] - ((v["z"] * st["mul"]) // st["div"] + st["add"])
        cx, cy = r["x"] // HEIGHT_TILE, r["y"] // HEIGHT_TILE
        if any(x0 <= cx <= x1 and y0 <= cy <= y1 for x0, y0, x1, y1 in st["massifs"]):
            inside.append(abs(d))
        else:
            outside.append(abs(d))
            per_class[r["class"]].append(abs(d))
            top.append((abs(d), r["class"], r["x"], r["y"], r["z"], v["z"]))
    top.sort(reverse=True)
    return {
        "z_stamp": {k: st[k] for k in ("mul", "div", "add", "uniform")},
        "massifs": len(st["massifs"]),
        "stamped": stamped, "paired": paired, "no_z": no_z, "unpaired": unpaired,
        "outside_n": len(outside), "outside_exact": sum(1 for d in outside if d == 0),
        "outside_p50": pct(outside, .5), "outside_p90": pct(outside, .9),
        "outside_p99": pct(outside, .99), "outside_max": max(outside, default=None),
        "inside_n": len(inside), "inside_exact": sum(1 for d in inside if d == 0),
        "inside_p50": pct(inside, .5), "inside_p90": pct(inside, .9),
        "inside_max": max(inside, default=None),
        "top_outside": [{"abs_delta": t[0], "class": t[1], "x": t[2], "y": t[3],
                         "z": t[4], "vanilla_z": t[5]} for t in top[:TOP_N]],
        "worst_classes": sorted(
            ({"class": c, "n": len(ds), "exact": sum(1 for d in ds if d == 0),
              "p50": pct(ds, .5), "max": max(ds)} for c, ds in per_class.items()),
            key=lambda e: -e["max"])[:8],
    }


def main():
    vtag, etag, zones_txt, out_json = sys.argv[1:5]
    _vmeta, vrows, _a, _b = compare.parse_dump(OUT / f"objects-{vtag}.csv")
    emeta, erows, _c, _d = compare.parse_dump(OUT / f"objects-{etag}.csv")
    stamp = meta_stamp(emeta) if zones_txt == "-" else read_stamp(zones_txt)

    result = {"vanilla": vtag, "expanded": etag, "zones": zones_txt, "maps": {}}
    for m in ("surface", "underground"):
        if m in stamp:
            result["maps"][m] = score_map(vrows[m], erows[m], stamp[m])
    Path(out_json).write_text(json.dumps(result, indent=2), encoding="utf-8")
    for m, v in result["maps"].items():
        print(f"[{m}] affine {v['z_stamp']['mul']}/{v['z_stamp']['div']}"
              f"+{v['z_stamp']['add']} massifs={v['massifs']}")
        print(f"   outside n={v['outside_n']} exact={v['outside_exact']} "
              f"p50={v['outside_p50']} p90={v['outside_p90']} p99={v['outside_p99']} "
              f"max={v['outside_max']}")
        print(f"   inside  n={v['inside_n']} exact={v['inside_exact']} "
              f"p50={v['inside_p50']} p90={v['inside_p90']} max={v['inside_max']}")
        for t in v["top_outside"][:5]:
            print(f"     TOP |d|={t['abs_delta']:<7} {t['class']:<24} "
                  f"at ({t['x']},{t['y']}) z={t['z']} vz={t['vanilla_z']}")
    print("->", out_json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
