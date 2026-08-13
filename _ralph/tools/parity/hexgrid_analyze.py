"""Decide whether GridObjectList is derived infrastructure or evidence of divergence.

A GridObjectList is an engine collision bucket: one exists exactly at every hex node
where 2+ gridded shapes overlap (Lua/GridObject.lua).  Its count is therefore not a
free number - it is a FUNCTION of the placed gridded objects' footprints.  This tool
reads the game-side census written by hexgrid_template.lua and, per map:

  * recomputes the predicted bucket set from the O rows (nodes covered by 2+ objects,
    using the node lists the engine itself produced) and compares it record-by-record
    with the observed B rows;
  * verifies every bucket member handle resolves to a live object, and that the member
    is one of the objects registered at that node;
  * reports the class multiset of the gridded population and of the bucket members.

Usage: python hexgrid_analyze.py <dir with hexgrid-vanilla.txt / hexgrid-expanded.txt>
       [--json <path>]
"""

import collections
import json
import sys
from pathlib import Path

MAPS = ("surface", "underground")


def parse(path):
    meta = collections.defaultdict(dict)
    buckets = collections.defaultdict(list)
    objects = collections.defaultdict(list)
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        if line.startswith("#meta,"):
            _, tag, key, value = line.split(",", 3)
            meta[tag][key] = value
            continue
        if line.startswith("#"):
            continue
        parts = line.split(",")
        kind, tag = parts[0], parts[1]
        if kind == "B":
            node_q, node_r, x, y, count, members = parts[2], parts[3], parts[4], parts[5], parts[6], parts[7] if len(parts) > 7 else ""
            entry = {
                "node": (node_q, node_r),
                "pos": (x, y),
                "count": int(count),
                "members": [],
            }
            for m in filter(None, members.split("|")):
                cls, handle, valid, mq, mr = (m.split(":") + ["", "", "", "", ""])[:5]
                entry["members"].append({
                    "class": cls, "handle": handle, "valid": valid == "true",
                    "node": (mq, mr),
                })
            buckets[tag].append(entry)
        elif kind == "O":
            (cls, handle, x, y, hq, hr, angle, direction, applied, shape_points) = parts[2:12]
            nodes = parts[12] if len(parts) > 12 else ""
            objects[tag].append({
                "class": cls, "handle": handle, "pos": (x, y), "hex": (hq, hr),
                "angle": angle, "dir": direction, "grids_applied": applied == "true",
                "shape_points": int(shape_points or 0),
                "nodes": [tuple(n.split(";")) for n in filter(None, nodes.split(" "))],
            })
    return meta, buckets, objects


def analyze(tag_label, meta, buckets, objects):
    """Recompute the bucket set from the registered footprints and compare."""
    occupancy = collections.defaultdict(list)
    for obj in objects:
        for node in obj["nodes"]:
            occupancy[node].append(obj)
    predicted = {n for n, objs in occupancy.items() if len(objs) >= 2}
    observed = {b["node"] for b in buckets}

    missing_buckets = sorted(predicted - observed)      # overlap with no engine bucket
    extra_buckets = sorted(observed - predicted)        # bucket with no computed overlap
    dead_members = [
        (b["node"], m) for b in buckets for m in b["members"] if not m["valid"]
    ]
    # every member must be one of the objects the footprint computation places at that node
    mismatched = []
    for b in buckets:
        want = {o["handle"] for o in occupancy.get(b["node"], [])}
        have = {m["handle"] for m in b["members"]}
        if want != have:
            mismatched.append({"node": b["node"], "bucket": sorted(have), "computed": sorted(want)})

    member_classes = collections.Counter(
        m["class"] for b in buckets for m in b["members"])
    gridded_classes = collections.Counter(o["class"] for o in objects)
    footprint = collections.Counter(
        (o["class"], len(o["nodes"])) for o in objects)
    unapplied = [o["handle"] for o in objects if not o["grids_applied"]]

    result = {
        "map": tag_label,
        "buckets_observed": len(observed),
        "buckets_predicted": len(predicted),
        "bucket_rows": len(buckets),
        "predicted_not_observed": len(missing_buckets),
        "observed_not_predicted": len(extra_buckets),
        "membership_mismatches": len(mismatched),
        "dead_member_handles": len(dead_members),
        "gridded_objects": len(objects),
        "gridded_classes": dict(gridded_classes),
        "member_classes": dict(member_classes),
        "footprint_sizes": {f"{c}:{n}": k for (c, n), k in footprint.items()},
        "objects_without_grids_applied": len(unapplied),
        "derivation_exact": (
            not missing_buckets and not extra_buckets and not mismatched and not dead_members
        ),
        "examples": {
            "predicted_not_observed": missing_buckets[:10],
            "observed_not_predicted": extra_buckets[:10],
            "membership_mismatches": mismatched[:5],
            "dead_members": [(n, m["class"], m["handle"]) for n, m in dead_members[:10]],
        },
    }
    return result


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = Path(sys.argv[1])
    out_json = None
    if "--json" in sys.argv:
        out_json = Path(sys.argv[sys.argv.index("--json") + 1])

    report = {}
    for side in ("vanilla", "expanded"):
        path = root / f"hexgrid-{side}.txt"
        if not path.exists():
            print(f"MISSING {path}")
            continue
        meta, buckets, objects = parse(path)
        report[side] = {}
        for mp in MAPS:
            if meta.get(mp, {}).get("present") != "true":
                continue
            res = analyze(mp, meta[mp], buckets.get(mp, []), objects.get(mp, []))
            res["meta"] = meta[mp]
            report[side][mp] = res
            print(f"\n=== {side} / {mp} ===")
            print(f"  buckets observed {res['buckets_observed']} "
                  f"predicted {res['buckets_predicted']} "
                  f"(predicted-not-observed {res['predicted_not_observed']}, "
                  f"observed-not-predicted {res['observed_not_predicted']})")
            print(f"  membership mismatches {res['membership_mismatches']}, "
                  f"dead member handles {res['dead_member_handles']}")
            print(f"  gridded objects {res['gridded_objects']}: "
                  f"{dict(sorted(res['gridded_classes'].items(), key=lambda kv: -kv[1]))}")
            print(f"  bucket member classes: "
                  f"{dict(sorted(res['member_classes'].items(), key=lambda kv: -kv[1]))}")
            print(f"  footprint sizes (class:nodes -> objects): "
                  f"{dict(sorted(res['footprint_sizes'].items()))}")
            print(f"  DERIVATION EXACT: {res['derivation_exact']}")
            for key, sample in res["examples"].items():
                if sample:
                    print(f"    {key}: {sample}")

    # cross-twin comparison of the derived population
    both = report.get("vanilla", {}), report.get("expanded", {})
    if all(both):
        print("\n=== derived-population comparison (vanilla -> expanded) ===")
        for mp in MAPS:
            v, e = both[0].get(mp), both[1].get(mp)
            if not v or not e:
                continue
            print(f"  {mp}: buckets {v['buckets_observed']} -> {e['buckets_observed']}; "
                  f"gridded objects {v['gridded_objects']} -> {e['gridded_objects']}; "
                  f"derivation exact {v['derivation_exact']} / {e['derivation_exact']}")
            vc, ec = v["gridded_classes"], e["gridded_classes"]
            diff = {k: (vc.get(k, 0), ec.get(k, 0)) for k in sorted(set(vc) | set(ec))
                    if vc.get(k, 0) != ec.get(k, 0)}
            print(f"    gridded classes differing: {diff or 'none'}")

    if out_json:
        out_json.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
        print(f"\njson -> {out_json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
