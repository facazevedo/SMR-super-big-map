"""full-z-parity gate `pass-exact-outside-zones`: per-object self-cell passability.

The object-parity gates prove every vanilla object exists once in the expanded map at the
stretched pose; they say nothing about whether it stands on ground the engine considers
passable.  Passability is a SLOPE threshold, so it is the sharpest visible consequence of
the Z transform: with the old adaptive-Z reduction every slope came out at ~82% of vanilla
and 289 of 42S28W's surface objects sat on a self cell whose passability disagreed with
vanilla (223 of them one-way false->true).  Under a true 4/3 similarity the slopes are the
vanilla slopes, so the self cell must agree.

The gate is the SELF cell only.  `pass_probe.lua` also samples three rings at eight compass
points; those are diagnostic, because ring geometry legitimately differs under the stretch
(a ring of fixed source radius crosses different terrain once the map is 4/3 bigger, and the
8 sampled bearings land on different cells).

Objects are joined by (map, class, source position) - the expanded twin stamps every carried
object with SuperBigMapNativeSourceX/Y and `pass_probe.lua` emits that as src_x/src_y, so a
vanilla row and its expanded counterpart share a key.  Duplicate keys are matched as a
multiset (pop one per pair), exactly like `zverdict.py`.  Objects the mod itself creates carry
no stamp and therefore never pair; they are reported as `expanded_only`, not scored - there
is no vanilla object to compare them with.

Inside/outside is decided per object from the run's own Z stamp: an object whose destination
cell falls in a massif crop bbox is INSIDE a compression zone, where the terrain is
deliberately not the similarity image and passability is whatever the engine recomputes from
the compressed ground (contract steps 3, 6 and gate `pass-real-inside-zones`).  A crop bbox is
a superset of its massif, so this exemption is conservative - it can only move objects out of
the scored set, never hide a difference outside a zone.

Usage:
  python passverdict.py <vanilla_tag> <expanded_tag> <zones_txt|-> <out_json>

Exit 0 only when no scored outside-zone object differs on its self cell, on every map.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

import zverdict

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
HEIGHT_TILE = 100  # const.HeightTileSize: world units per terrain tile
TOP_N = 20


def read_pass(path):
    rows = []
    head = None
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if not line:
            continue
        if line.startswith("#"):
            head = line[1:].split(",")
            continue
        if head is None:
            continue
        f = line.split(",")
        r = dict(zip(head, f))
        for k in ("src_x", "src_y", "x", "y", "r600", "r1200", "r2400",
                  "blocked_ring_count", "samples"):
            try:
                r[k] = int(r[k])
            except (KeyError, TypeError, ValueError):
                r[k] = None
        rows.append(r)
    return rows


def score_map(vrows, erows, massifs, diffs):
    pool = defaultdict(list)
    for r in vrows:
        pool[(r["class"], r["src_x"], r["src_y"])].append(r)

    paired = expanded_only = unknown = 0
    out_n = out_diff = in_n = in_diff = 0
    f2t = t2f = 0
    ring_out_n = ring_out_diff = 0
    top = []
    per_class = defaultdict(lambda: [0, 0])
    for r in erows:
        bucket = pool.get((r["class"], r["src_x"], r["src_y"]))
        if not bucket:
            expanded_only += 1
            continue
        v = bucket.pop()
        paired += 1
        if v["self_pass"] not in ("true", "false") or r["self_pass"] not in ("true", "false"):
            unknown += 1
            continue
        cx, cy = r["x"] // HEIGHT_TILE, r["y"] // HEIGHT_TILE
        inside = any(x0 <= cx <= x1 and y0 <= cy <= y1 for x0, y0, x1, y1 in massifs)
        differs = v["self_pass"] != r["self_pass"]
        if inside:
            in_n += 1
            in_diff += differs
            # In-zone differences are NOT scored (the ground there is deliberately not the
            # similarity image), but they are the raw material of `pass-real-inside-zones`,
            # so they are written out too, flagged, and must never be confused with a
            # scored one when a figure or a diagnosis reads the CSV.
            if differs:
                diffs.append(("inside", r["class"], r["src_x"], r["src_y"], r["x"], r["y"],
                              v["self_pass"], r["self_pass"]))
            continue
        out_n += 1
        per_class[r["class"]][0] += 1
        ring_out_n += 1
        if (v["r600"], v["r1200"], v["r2400"]) != (r["r600"], r["r1200"], r["r2400"]):
            ring_out_diff += 1
        if not differs:
            continue
        out_diff += 1
        per_class[r["class"]][1] += 1
        if v["self_pass"] == "false":
            f2t += 1
        else:
            t2f += 1
        if len(top) < TOP_N:
            top.append({"class": r["class"], "src_x": r["src_x"], "src_y": r["src_y"],
                        "x": r["x"], "y": r["y"],
                        "vanilla": v["self_pass"], "expanded": r["self_pass"]})
        diffs.append(("outside", r["class"], r["src_x"], r["src_y"], r["x"], r["y"],
                      v["self_pass"], r["self_pass"]))
    return {
        "massifs": len(massifs),
        "paired": paired, "expanded_only": expanded_only,
        "vanilla_only": sum(len(b) for b in pool.values()),
        "unknown_pass": unknown,
        "outside_n": out_n, "outside_diff": out_diff,
        "outside_false_to_true": f2t, "outside_true_to_false": t2f,
        "inside_n": in_n, "inside_diff": in_diff,
        "ring_outside_n": ring_out_n, "ring_outside_diff": ring_out_diff,
        "diff_examples": top,
        "diff_classes": sorted(
            ({"class": c, "n": n, "diff": d} for c, (n, d) in per_class.items() if d),
            key=lambda e: -e["diff"])[:12],
    }


def main():
    vtag, etag, zones_txt, out_json = sys.argv[1:5]
    vrows = read_pass(OUT / f"pass-{vtag}.csv")
    erows = read_pass(OUT / f"pass-{etag}.csv")
    stamp = {} if zones_txt == "-" else zverdict.read_stamp(zones_txt)

    result = {"vanilla": vtag, "expanded": etag, "zones": zones_txt, "maps": {}}
    # Every scored difference is written out beside the verdict: 300 rows of "which object,
    # where, which way" is what a diagnosis needs, and it does not belong in the JSON.
    csv_path = Path(out_json).with_name(Path(out_json).stem + "_diffs.csv")
    csv_rows = ["map,zone,class,src_x,src_y,x,y,vanilla,expanded"]
    for m in ("surface", "underground"):
        v = [r for r in vrows if r["map"] == m]
        e = [r for r in erows if r["map"] == m]
        if not v and not e:
            continue
        diffs = []
        result["maps"][m] = score_map(v, e, stamp.get(m, {}).get("massifs", []), diffs)
        csv_rows.extend(m + "," + ",".join(str(c) for c in d) for d in diffs)
    csv_path.write_text("\n".join(csv_rows) + "\n", encoding="utf-8")
    result["diffs_csv"] = str(csv_path)
    result["gate_outside_diff_total"] = sum(
        s["outside_diff"] for s in result["maps"].values())
    result["gate_surface_outside_diff"] = result["maps"].get("surface", {}).get(
        "outside_diff")
    result["pass"] = result["gate_outside_diff_total"] == 0

    Path(out_json).write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
