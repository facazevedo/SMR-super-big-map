"""Compare the 30S146E vanilla and expanded object dumps.

Three independent tests per map (surface, underground):

  A. Census      - per-class object counts must match exactly (the 1:1 claim).
  B. Provenance  - every expanded object's stamped SuperBigMapNativeSource(X,Y)
                   must correspond to exactly one vanilla object of the same class
                   at exactly that position (bijection by identity).
  C. Geometry    - independent of the stamps: match vanilla -> expanded per class
                   purely by predicted position (vanilla_xy * ratio) and report the
                   residual distance distribution (proportional placement).

Usage: python compare.py [out_dir]
"""

import json
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

INVALID_Z = 2147483647


def parse_dump(path):
    meta = defaultdict(dict)
    rows = defaultdict(list)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#meta,"):
                _, map_tag, key, value = line.split(",", 3)
                meta[map_tag][key] = value
                continue
            if line.startswith("#"):
                continue
            parts = line.split(",")
            if len(parts) < 14:
                continue
            (map_tag, cls, x, y, z, scale, angle,
             sx, sy, sz, sscale, sangle, sclass, transferred) = parts[:14]

            def fnum(v):
                if v == "":
                    return None
                try:
                    return int(v)
                except ValueError:
                    try:
                        return float(v)
                    except ValueError:
                        return None

            rows[map_tag].append({
                "class": cls,
                "x": fnum(x), "y": fnum(y), "z": fnum(z),
                "scale": fnum(scale), "angle": fnum(angle),
                "src_x": fnum(sx), "src_y": fnum(sy), "src_z": fnum(sz),
                "src_scale": fnum(sscale), "src_angle": fnum(sangle),
                "src_class": sclass or None,
                "transferred": transferred == "1",
            })
    return meta, rows


def rnd(v):
    return math.floor(v + 0.5) if v >= 0 else math.ceil(v - 0.5)


def census(vrows, erows):
    vc, ec = Counter(r["class"] for r in vrows), Counter(r["class"] for r in erows)
    classes = sorted(set(vc) | set(ec))
    same, diff = [], []
    for c in classes:
        if vc[c] == ec[c]:
            same.append((c, vc[c]))
        else:
            diff.append((c, vc[c], ec[c]))
    return vc, ec, same, diff


def provenance(vrows, erows):
    """Match expanded objects to vanilla objects by their stamped source position."""
    pool = defaultdict(list)
    for i, r in enumerate(vrows):
        if r["x"] is None:
            continue
        pool[(r["class"], r["x"], r["y"])].append(i)

    used = set()
    matched = 0
    stamped = 0
    unstamped = []
    unmatched = []
    for r in erows:
        if r["src_x"] is None or r["src_y"] is None:
            unstamped.append(r)
            continue
        stamped += 1
        key = (r["src_class"] or r["class"], r["src_x"], r["src_y"])
        bucket = pool.get(key)
        if bucket:
            matched += 1
            used.add(bucket.pop())
        else:
            unmatched.append(r)
    unconsumed = [vrows[i] for i in range(len(vrows)) if i not in used]
    return {
        "stamped": stamped,
        "unstamped": unstamped,
        "matched": matched,
        "unmatched_expanded": unmatched,
        "unconsumed_vanilla": unconsumed,
    }


def stretch_residuals(erows, rx, ry):
    """|actual_xy - src_xy*ratio| for every stamped expanded object."""
    per_class = defaultdict(list)
    for r in erows:
        if r["src_x"] is None or r["x"] is None:
            continue
        dx = r["x"] - rnd(r["src_x"] * rx)
        dy = r["y"] - rnd(r["src_y"] * ry)
        per_class[r["class"]].append(math.hypot(dx, dy))
    return per_class


class Index:
    """Bucketed nearest-neighbour index over 2D points."""

    def __init__(self, points, cell):
        self.cell = cell
        self.buckets = defaultdict(list)
        for i, (x, y) in enumerate(points):
            self.buckets[(x // cell, y // cell)].append(i)

    def pop_nearest(self, x, y, alive, max_r):
        best, bestd = None, None
        reach = int(max_r // self.cell) + 1
        cx, cy = x // self.cell, y // self.cell
        for gx in range(cx - reach, cx + reach + 1):
            for gy in range(cy - reach, cy + reach + 1):
                for i in self.buckets.get((gx, gy), ()):
                    if i not in alive:
                        continue
                    d = math.hypot(alive[i][0] - x, alive[i][1] - y)
                    if bestd is None or d < bestd:
                        best, bestd = i, d
        if best is not None and bestd <= max_r:
            return best, bestd
        return None, None


def geometric_match(vrows, erows, rx, ry, max_r=200000):
    """Stamp-independent: per class, match each vanilla object to the nearest
    expanded object relative to its predicted position."""
    v_by, e_by = defaultdict(list), defaultdict(list)
    for r in vrows:
        if r["x"] is not None:
            v_by[r["class"]].append(r)
    for r in erows:
        if r["x"] is not None:
            e_by[r["class"]].append(r)

    per_class = {}
    for cls in sorted(set(v_by) | set(e_by)):
        vs, es = v_by.get(cls, []), e_by.get(cls, [])
        if not vs or not es:
            per_class[cls] = {"v": len(vs), "e": len(es), "matched": 0, "dists": []}
            continue
        pts = [(r["x"], r["y"]) for r in es]
        alive = {i: p for i, p in enumerate(pts)}
        idx = Index(pts, cell=50000)
        dists, unmatched = [], 0
        # Match tightest predictions first so exact hits aren't stolen by outliers.
        order = sorted(range(len(vs)), key=lambda i: (vs[i]["x"], vs[i]["y"]))
        for i in order:
            r = vs[i]
            px, py = rnd(r["x"] * rx), rnd(r["y"] * ry)
            j, d = idx.pop_nearest(px, py, alive, max_r)
            if j is None:
                unmatched += 1
            else:
                del alive[j]
                dists.append(d)
        per_class[cls] = {
            "v": len(vs), "e": len(es), "matched": len(dists),
            "unmatched_v": unmatched, "leftover_e": len(alive), "dists": dists,
        }
    return per_class


def dist_summary(d):
    if not d:
        return "n/a"
    d = sorted(d)
    return (f"n={len(d)} max={d[-1]:.0f} p99={d[int(len(d) * 0.99)]:.0f} "
            f"median={statistics.median(d):.0f} mean={statistics.fmean(d):.1f}")


def report_map(tag, vrows, erows, rx, ry, out):
    def w(s=""):
        out.append(s)

    w(f"\n{'=' * 78}")
    w(f"  {tag.upper()}   vanilla={len(vrows)} objects   expanded={len(erows)} objects")
    w(f"{'=' * 78}")

    vc, ec, same, diff = census(vrows, erows)
    w(f"\n-- A. CLASS CENSUS --")
    w(f"   total objects       : vanilla {len(vrows)} vs expanded {len(erows)}  "
      f"{'MATCH' if len(vrows) == len(erows) else 'MISMATCH (' + str(len(erows) - len(vrows)) + ')'}")
    w(f"   distinct classes    : vanilla {len(vc)} vs expanded {len(ec)}")
    w(f"   classes matching 1:1: {len(same)}")
    w(f"   classes differing   : {len(diff)}")
    if diff:
        w("     class                                   vanilla  expanded    delta")
        for c, v, e in sorted(diff, key=lambda t: -abs(t[1] - t[2]))[:40]:
            w(f"     {c[:38]:<38} {v:>8} {e:>9} {e - v:>+8}")

    prov = provenance(vrows, erows)
    w(f"\n-- B. PROVENANCE BIJECTION (expanded source stamp -> vanilla object) --")
    w(f"   expanded objects carrying a source stamp : {prov['stamped']}")
    w(f"   ... matched to a distinct vanilla object : {prov['matched']}")
    w(f"   ... stamp with no vanilla counterpart    : {len(prov['unmatched_expanded'])}")
    w(f"   expanded objects with NO source stamp    : {len(prov['unstamped'])}")
    w(f"   vanilla objects never claimed by a stamp : {len(prov['unconsumed_vanilla'])}")
    if prov["unstamped"]:
        w("   unstamped expanded classes (top 15):")
        for c, n in Counter(r["class"] for r in prov["unstamped"]).most_common(15):
            w(f"     {c[:44]:<44} {n:>7}")
    if prov["unconsumed_vanilla"]:
        w("   unclaimed vanilla classes (top 15):")
        for c, n in Counter(r["class"] for r in prov["unconsumed_vanilla"]).most_common(15):
            w(f"     {c[:44]:<44} {n:>7}")

    res = stretch_residuals(erows, rx, ry)
    allres = [d for v in res.values() for d in v]
    w(f"\n-- C. STRETCH PROPORTIONALITY  (|actual_xy - src_xy * {rx:.6f}|, world units) --")
    w(f"   all stamped objects : {dist_summary(allres)}")
    if allres:
        exact = sum(1 for d in allres if d <= 1.0)
        w(f"   within 1 wu (pure rounding) : {exact}/{len(allres)} "
          f"({100.0 * exact / len(allres):.3f}%)")
    worst = sorted(res.items(), key=lambda kv: -max(kv[1], default=0))[:15]
    if worst and any(max(v, default=0) > 1 for _, v in worst):
        w("   classes with residual > 1 wu (top 15 by max):")
        for c, d in worst:
            if max(d, default=0) > 1:
                w(f"     {c[:38]:<38} {dist_summary(d)}")

    geo = geometric_match(vrows, erows, rx, ry)
    tot_m = sum(g["matched"] for g in geo.values())
    tot_u = sum(g.get("unmatched_v", 0) for g in geo.values())
    tot_l = sum(g.get("leftover_e", 0) for g in geo.values())
    alld = [d for g in geo.values() for d in g["dists"]]
    w(f"\n-- D. STAMP-INDEPENDENT GEOMETRIC MATCH (vanilla_xy * ratio -> nearest expanded) --")
    w(f"   matched pairs        : {tot_m}")
    w(f"   vanilla unmatched    : {tot_u}")
    w(f"   expanded left over   : {tot_l}")
    w(f"   residual distance    : {dist_summary(alld)}")
    if alld:
        for thr in (1, 100, 1000, 10000):
            n = sum(1 for d in alld if d <= thr)
            w(f"     within {thr:>6} wu : {n}/{len(alld)} ({100.0 * n / len(alld):.3f}%)")

    return {
        "vanilla_objects": len(vrows),
        "expanded_objects": len(erows),
        "classes_matching": len(same),
        "classes_differing": len(diff),
        "class_diffs": [{"class": c, "vanilla": v, "expanded": e} for c, v, e in diff],
        "provenance_stamped": prov["stamped"],
        "provenance_matched": prov["matched"],
        "provenance_unmatched_expanded": len(prov["unmatched_expanded"]),
        "provenance_unstamped_expanded": len(prov["unstamped"]),
        "provenance_unconsumed_vanilla": len(prov["unconsumed_vanilla"]),
        "stretch_max_residual": max(allres) if allres else None,
        "geometric_matched": tot_m,
        "geometric_unmatched_vanilla": tot_u,
        "geometric_leftover_expanded": tot_l,
        "geometric_max_residual": max(alld) if alld else None,
    }


def main():
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / "out"
    vmeta, vrows = parse_dump(out_dir / "objects-vanilla.csv")
    emeta, erows = parse_dump(out_dir / "objects-expanded.csv")

    lines = []
    lines.append("30S146E  VANILLA vs EXPANDED  object parity report")
    lines.append("=" * 78)

    for tag in ("surface", "underground"):
        lines.append(f"\n[{tag}] metadata")
        keys = ["mapdata_width", "mapdata_height", "blank_map_id", "gen_seed", "gen_hash",
                "SuperBigMapSourceWidthTiles", "SuperBigMapDesiredWidthTiles",
                "SuperBigMapZScaleMul", "SuperBigMapZScaleDiv", "SuperBigMapZScaleAdd",
                "SuperBigMapExpanded", "SuperBigMapUndergroundPrepared",
                "raw_object_count", "dumped_object_count"]
        for k in keys:
            v, e = vmeta[tag].get(k, "-"), emeta[tag].get(k, "-")
            flag = ""
            if k in ("gen_seed", "gen_hash") and v != "-" and e != "-":
                flag = "   <== MATCH" if v == e else "   <== DIFFERENT"
            lines.append(f"   {k:<38} vanilla={v:<14} expanded={e}{flag}")

    summary = {}
    for tag in ("surface", "underground"):
        vw = int(vmeta[tag].get("mapdata_width") or 0)
        ew = int(emeta[tag].get("mapdata_width") or 0)
        vh = int(vmeta[tag].get("mapdata_height") or 0)
        eh = int(emeta[tag].get("mapdata_height") or 0)
        rx = (ew / vw) if vw else 1.0
        ry = (eh / vh) if vh else 1.0
        lines.append(f"\n[{tag}] derived stretch ratio: x={rx:.6f}  y={ry:.6f} "
                     f"({vw}->{ew} tiles)")
        summary[tag] = report_map(tag, vrows[tag], erows[tag], rx, ry, lines)
        summary[tag]["ratio_x"] = rx
        summary[tag]["ratio_y"] = ry

    text = "\n".join(lines)
    print(text)
    (out_dir / "parity_report.txt").write_text(text, encoding="utf-8")
    (out_dir / "parity_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"\nreport  -> {out_dir / 'parity_report.txt'}")
    print(f"summary -> {out_dir / 'parity_summary.json'}")


if __name__ == "__main__":
    main()
