"""Score the object footprint-imprint census (`passimprint_probe.lua`).

The question 028 left open was whether the expanded map applies object surfaces to its pass grid
at all: on the vanilla twin the `BottomlessPit` wonder writes 20,855 of a 40,401-cell window and
its expanded clone writes nothing anywhere.  Two very different defects fit that:

  (A) map-wide - the expanded map's pass rebuild never rasterises ANY object's surfaces, which
      would also explain the ~5:1 false->true bias in every at-object measurement;
  (B) object-specific - the machinery works, and this one clone is not registered.

The probe measures, per object with efApplyToGrids and real ApplyToGrids surfaces, the blocked
rate INSIDE its own world bbox against a ring just outside it.  This scorer joins the twins by
(map, class, source position) so the same object is compared on both maps, and reports:

  * per twin and per map, the inside/ring rates and how many objects imprint at all;
  * matched pairs whose imprint is LOST on the expanded map (vanilla mostly blocked inside,
    expanded free) and the classes they belong to - the defective set, if (B);
  * the same for gained imprints, as the symmetric control;
  * the `BottomlessPit` pair explicitly, because that is the object 028 caught.

Objects outside VANILLA's play area are dropped: there the PassBorder rule blocks ground by
decree (019) and the expanded map sets PassBorder = 0, so their comparison is one-way by
construction and says nothing about imprints.

Usage:  passimprintcheck.py <vanilla.csv> <expanded.csv> <out.json>
"""
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

TOL = 300.0        # source wu; matched objects must be this close after the 4/3 division
LOST_MIN = 0.60    # vanilla inside-blocked fraction that counts as "vanilla imprints here"
LOST_MAX = 0.10    # expanded inside-blocked fraction that counts as "expanded does not"


def read(path):
    maps, rows = {}, []
    header = None
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        if line.startswith("#meta"):
            continue
        if line.startswith("#map,"):
            parts = line.split(",")
            info = {"map": parts[1]}
            for p in parts[2:]:
                k, _, v = p.partition("=")
                info[k] = v
            maps[info["map"]] = info
            continue
        if line.startswith("map,idx,"):
            header = line.split(",")
            continue
        if line.startswith("#"):
            continue
        parts = line.split(",")
        if header is None or len(parts) != len(header):
            continue
        r = dict(zip(header, parts))
        for k in ("sx", "sy", "x", "y", "bw", "bh", "in_n", "in_blocked", "ring_n", "ring_blocked"):
            r[k] = int(r[k])
        rows.append(r)
    return maps, rows


def rate(num, den):
    return round(100.0 * num / den, 3) if den else None


def totals(rows, env):
    sel = [r for r in rows if r["map"] == env]
    in_n = sum(r["in_n"] for r in sel)
    in_b = sum(r["in_blocked"] for r in sel)
    rg_n = sum(r["ring_n"] for r in sel)
    rg_b = sum(r["ring_blocked"] for r in sel)
    return {
        "objects": len(sel),
        "inside_n": in_n, "inside_blocked": in_b, "inside_pct": rate(in_b, in_n),
        "ring_n": rg_n, "ring_blocked": rg_b, "ring_pct": rate(rg_b, rg_n),
        "objs_with_imprint": sum(1 for r in sel if r["in_blocked"] > 0),
        "objs_fully_blocked": sum(1 for r in sel if r["in_n"] and r["in_blocked"] == r["in_n"]),
    }


def match(van, exp, env):
    """Greedy nearest match within TOL source wu, per (map, class)."""
    buckets = defaultdict(list)
    for r in exp:
        if r["map"] != env:
            continue
        buckets[(r["class"], int(r["sx"] // 500), int(r["sy"] // 500))].append(r)
    used = set()
    pairs, unmatched = [], []
    for v in van:
        if v["map"] != env:
            continue
        best, bestd = None, TOL * TOL
        bx, by = int(v["sx"] // 500), int(v["sy"] // 500)
        for ox in (-1, 0, 1):
            for oy in (-1, 0, 1):
                for e in buckets.get((v["class"], bx + ox, by + oy), ()):
                    if id(e) in used:
                        continue
                    d2 = (e["sx"] - v["sx"]) ** 2 + (e["sy"] - v["sy"]) ** 2
                    if d2 < bestd:
                        best, bestd = e, d2
        if best is None:
            unmatched.append(v)
        else:
            used.add(id(best))
            pairs.append((v, best, math.sqrt(bestd)))
    return pairs, unmatched


def frac(r):
    return (r["in_blocked"] / r["in_n"]) if r["in_n"] else None


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    van_maps, van = read(sys.argv[1])
    exp_maps, exp = read(sys.argv[2])
    out_path = Path(sys.argv[3])

    report = {"vanilla_csv": sys.argv[1], "expanded_csv": sys.argv[2],
              "vanilla_maps": van_maps, "expanded_maps": exp_maps, "environments": {}}
    verdicts = []
    for env in ("surface", "underground"):
        tv, te = totals(van, env), totals(exp, env)
        pairs, unmatched = match(van, exp, env)
        # In-play on the VANILLA twin only: outside it the border rule decides, not objects.
        inplay = [(v, e, d) for (v, e, d) in pairs if v["inplay"] == "1"]
        lost, gained = [], []
        for v, e, d in inplay:
            fv, fe = frac(v), frac(e)
            if fv is None or fe is None:
                continue
            if fv >= LOST_MIN and fe <= LOST_MAX:
                lost.append((v, e))
            if fe >= LOST_MIN and fv <= LOST_MAX:
                gained.append((v, e))
        by_class_lost = defaultdict(int)
        for v, _ in lost:
            by_class_lost[v["class"]] += 1
        by_class_gained = defaultdict(int)
        for v, _ in gained:
            by_class_gained[v["class"]] += 1

        pair_in_v = sum(v["in_blocked"] for v, _, _ in inplay)
        pair_in_e = sum(e["in_blocked"] for _, e, _ in inplay)
        pair_n = sum(v["in_n"] for v, _, _ in inplay)
        pair_rg_v = sum(v["ring_blocked"] for v, _, _ in inplay)
        pair_rg_e = sum(e["ring_blocked"] for _, e, _ in inplay)
        pair_rg_n = sum(v["ring_n"] for v, _, _ in inplay)

        pit = [(v, e) for v, e, _ in pairs if "BottomlessPit" in v["class"]]
        env_rep = {
            "vanilla": tv, "expanded": te,
            "matched_pairs": len(pairs), "unmatched_vanilla": len(unmatched),
            "matched_in_vanilla_play_area": len(inplay),
            "paired_inside_pct_vanilla": rate(pair_in_v, pair_n),
            "paired_inside_pct_expanded": rate(pair_in_e, pair_n),
            "paired_ring_pct_vanilla": rate(pair_rg_v, pair_rg_n),
            "paired_ring_pct_expanded": rate(pair_rg_e, pair_rg_n),
            "imprint_lost": len(lost), "imprint_gained": len(gained),
            "imprint_lost_by_class": dict(sorted(by_class_lost.items(),
                                                 key=lambda kv: -kv[1])[:20]),
            "imprint_gained_by_class": dict(sorted(by_class_gained.items(),
                                                   key=lambda kv: -kv[1])[:20]),
            "lost_examples": [
                {"class": v["class"], "entity": v["entity"], "sx": v["sx"], "sy": v["sy"],
                 "bw": v["bw"], "bh": v["bh"], "van_in": f'{v["in_blocked"]}/{v["in_n"]}',
                 "exp_in": f'{e["in_blocked"]}/{e["in_n"]}',
                 "van_ring": f'{v["ring_blocked"]}/{v["ring_n"]}',
                 "exp_ring": f'{e["ring_blocked"]}/{e["ring_n"]}',
                 "van_scale": v["scl"], "exp_scale": e["scl"],
                 "van_grids_applied": v["grids_applied"], "exp_grids_applied": e["grids_applied"]}
                for v, e in sorted(lost, key=lambda p: -(p[0]["bw"] * p[0]["bh"]))[:15]],
            "bottomless_pit": [
                {"class": v["class"], "entity": v["entity"], "sx": v["sx"], "sy": v["sy"],
                 "van_bw": v["bw"], "van_bh": v["bh"], "exp_bw": e["bw"], "exp_bh": e["bh"],
                 "van_in": f'{v["in_blocked"]}/{v["in_n"]}',
                 "exp_in": f'{e["in_blocked"]}/{e["in_n"]}',
                 "van_ring": f'{v["ring_blocked"]}/{v["ring_n"]}',
                 "exp_ring": f'{e["ring_blocked"]}/{e["ring_n"]}',
                 "van_scale": v["scl"], "exp_scale": e["scl"],
                 "van_grids_applied": v["grids_applied"],
                 "exp_grids_applied": e["grids_applied"]}
                for v, e in pit],
        }
        report["environments"][env] = env_rep
        # The map-wide reading is refuted whenever the expanded twin's own inside rate stands
        # clear of its ring rate by a margin comparable to vanilla's.
        vm = (tv["inside_pct"] or 0) - (tv["ring_pct"] or 0)
        em = (te["inside_pct"] or 0) - (te["ring_pct"] or 0)
        verdicts.append({
            "env": env,
            "vanilla_inside_minus_ring": round(vm, 3),
            "expanded_inside_minus_ring": round(em, 3),
            "expanded_imprints": em > 0.5 * vm,
        })
    report["verdicts"] = verdicts
    report["reading"] = ("map_wide_failure_refuted"
                         if all(v["expanded_imprints"] for v in verdicts)
                         else "map_wide_failure_possible")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("verdicts", "reading")}, indent=2))
    for env in ("surface", "underground"):
        e = report["environments"][env]
        print(f"{env}: paired inside van {e['paired_inside_pct_vanilla']}% "
              f"exp {e['paired_inside_pct_expanded']}% | ring van {e['paired_ring_pct_vanilla']}% "
              f"exp {e['paired_ring_pct_expanded']}% | lost {e['imprint_lost']} "
              f"gained {e['imprint_gained']} of {e['matched_in_vanilla_play_area']} pairs")
        print(f"   pit: {e['bottomless_pit']}")
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
