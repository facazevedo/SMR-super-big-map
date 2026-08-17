"""Score contract step 1 - the interior floor shift - offline, against the dumped grids.

WHAT THIS SCORES.  Every other terrain gate in this workspace takes the map's stamped
`SuperBigMapZScaleAdd` (`zadd`) as GIVEN and checks the grid against it: `zonecheck.py`
verifies `post == floor(min(pre,src_cap)*zmul/zdiv) + zadd` cell by cell, so a zadd computed
by the WRONG RULE would still score green everywhere.  The contract's step 1 fixes that rule:

    shift = min(0, FLOOR - floor(interior_min * 4/3)),  FLOOR = 500 wu = 5 in-game metres

with `interior_min` measured on the INTERIOR of the SOURCE grid (one cell of border excluded)
and the `min(0, ...)` clamp making the shift DOWN-ONLY: a map whose scaled interior minimum
already sits at or below FLOOR keeps its lowlands exactly where the pure similarity puts them.

The rule is scorable offline because the vanilla twin's own surface dump IS that source grid
(6144^2 raw U16) and the expanded twin stamps the shift it applied.  Per case this tool checks:

  shift_matches      stamped zadd == min(0, FLOOR - floor(src_interior_min*zmul/zdiv)), exactly
  never_lift         zadd <= 0 (the clamp), on the case AND across every stamp ever dumped
  branch_rule        shifted (zadd<0)  -> the scaled interior minimum lands exactly on FLOOR
                     clamped (zadd==0) -> the scaled interior minimum was already <= FLOOR
  src_cap_rule       src_cap == floor((65535 - zadd)*zdiv/zmul), and every stamped massif
                     peaks above it while its base sits at or below it (contract step 2)
  floor_constant     the payload's own Z_FLOOR_WU literal equals the contract's FLOOR
  in_range           (with --pre) the final grid pins no cell to 0, i.e. nothing fell out of
                     the unsigned range, and its interior minimum is exactly
                     floor(pre_interior_min*zmul/zdiv) + zadd

The vanilla source grid is a TWIN of the expanded run, so the mandatory twin-identity pre-check
(061c) applies to every scored pair; run `.tmp_fzp_offsetdiag066.py <van> <exp> <label>` first.

CONTROLS.  `--perturb-src-min N` lifts the source grid's interior floor by N world units before
predicting - the counterfactual "this map's lowlands sat N units higher" - so a tool that merely
echoed the stamp cannot stay green; `--floor N` scores against a different floor constant, which
must fail every map, shifted and clamped alike.

Usage:
  python shiftcheck.py --case label=42S28W,vanilla=t73a,expanded=t47x,pre=t47x \
      --case label=30S146E,vanilla=t77a,expanded=t77x --out <json>
  python shiftcheck.py --case ... --perturb-src-min 100 --out <control json>
"""

from __future__ import annotations

import argparse
import glob
import json
import math
import os
import re
import sys

import numpy as np

CAP = 65535
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
PAYLOAD = os.path.abspath(os.path.join(HERE, "..", "..", "..", "Code", "sbm_terrain_copy.lua"))
CONTRACT_FLOOR = 500


def load_grid(path):
    raw = np.fromfile(path, dtype="<u2")
    side = int(round(math.sqrt(raw.size)))
    if side * side != raw.size or side < 3:
        raise SystemExit(f"{path}: {raw.size} u16 values is not a usable square grid")
    return raw.reshape((side, side))


def parse_stamp(path):
    """The height probe's stamp file -> {env: {...}}, [massif rows]."""
    maps, massifs = {}, []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            parts = line.strip().split(",")
            if not parts or not parts[0]:
                continue
            if parts[0] == "map":
                maps[parts[1]] = dict(kv.split("=", 1) for kv in parts[2:] if "=" in kv)
            elif parts[0] == "massif":
                d = dict(env=parts[1], index=int(parts[2]))
                d.update(dict(kv.split("=", 1) for kv in parts[3:] if "=" in kv))
                massifs.append(d)
    return maps, massifs


def payload_floor():
    """The FLOOR constant the payload itself compiles in (never a number typed twice)."""
    try:
        with open(PAYLOAD, "r", encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"\s*local\s+Z_FLOOR_WU\s*=\s*(\d+)", line)
                if m:
                    return int(m.group(1))
    except OSError:
        pass
    return None


def interior_min(grid, rim=1):
    n = grid.shape[0]
    return int(grid[rim:n - rim, rim:n - rim].min())


def rim_min(grid):
    return int(min(grid[0].min(), grid[-1].min(), grid[:, 0].min(), grid[:, -1].min()))


def predicted_shift(src_min, zmul, zdiv, floor_wu):
    return min(0, floor_wu - (src_min * zmul) // zdiv)


def score_case(case, floor_wu, perturb, out_dir):
    label = case["label"]
    van, exp = case["vanilla"], case["expanded"]
    pre_tag = case.get("pre")
    res = {"label": label, "vanilla": van, "expanded": exp, "checks": {}, "failed": []}

    maps, massifs = parse_stamp(os.path.join(out_dir, f"height-{exp}-zones.txt"))
    surf = maps.get("surface")
    if not surf:
        raise SystemExit(f"{exp}: stamp has no surface row")
    zmul, zdiv = int(surf["zmul"]), int(surf["zdiv"])
    zadd = int(surf["zadd"])
    zones = int(surf["zones"])
    res.update(zmul=zmul, zdiv=zdiv, zadd=zadd, zones=zones,
               measured_max=surf.get("measured_max"))

    src = load_grid(os.path.join(out_dir, f"height-{van}-surface.raw"))
    n = src.shape[0]
    if perturb:
        # Counterfactual: this map's lowlands sat N units higher.  Lifting the whole floor (not
        # just the cells holding the minimum, which only exposes the next level up) moves the
        # measured interior minimum by exactly N on every map, clamped branch included.
        inner = src[1:n - 1, 1:n - 1]
        m0 = int(inner.min())
        lifted = min(CAP, m0 + perturb)
        hit = int((inner < lifted).sum())
        inner[inner < lifted] = lifted
        res["perturbation"] = {"cells_raised": hit, "from": m0, "to": lifted}

    src_int_min = interior_min(src, 1)
    src_full_min = int(src.min())
    res["source"] = {
        "grid": int(n), "interior_min": src_int_min, "full_min": src_full_min,
        "rim_min": rim_min(src), "interior_min_rim2": interior_min(src, 2),
    }

    pred = predicted_shift(src_int_min, zmul, zdiv, floor_wu)
    pred_border = predicted_shift(src_full_min, zmul, zdiv, floor_wu)
    scaled_min = (src_int_min * zmul) // zdiv
    res["predicted_shift"] = pred
    res["scaled_interior_min"] = scaled_min
    # Invert the stamp: on the shifted branch floor(m*zmul/zdiv) == FLOOR - zadd pins the source
    # interior minimum the mod actually measured to a single integer, independent of this dump.
    if zadd < 0:
        target = floor_wu - zadd
        lo = -(-target * zdiv // zmul)                 # ceil(target*zdiv/zmul)
        hi = ((target + 1) * zdiv - 1) // zmul
        res["implied_source_interior_min"] = [int(lo), int(hi)]
    res["predicted_shift_border_included"] = pred_border
    res["border_would_change_shift"] = pred_border != pred

    res["checks"]["shift_matches"] = (zadd == pred)
    res["checks"]["never_lift"] = (zadd <= 0)
    if zadd < 0:
        res["branch"] = "shifted"
        res["checks"]["branch_rule"] = (scaled_min > floor_wu and scaled_min + zadd == floor_wu)
    else:
        res["branch"] = "clamped"
        res["checks"]["branch_rule"] = (scaled_min <= floor_wu)

    src_cap = ((CAP - zadd) * zdiv) // zmul
    if src_cap >= CAP:
        src_cap = CAP - 1
    res["src_cap"] = int(src_cap)
    peaks_over = sum(1 for m in massifs if m["env"] == "surface" and int(m["peak"]) > src_cap)
    bases_under = sum(1 for m in massifs if m["env"] == "surface" and int(m["base"]) <= src_cap)
    at_cap = sum(1 for m in massifs if m["env"] == "surface" and int(m["peak_img"]) == CAP)
    surf_massifs = sum(1 for m in massifs if m["env"] == "surface")
    res["massifs"] = {"stamped": zones, "rows": surf_massifs, "peak_over_src_cap": peaks_over,
                      "base_at_or_under_src_cap": bases_under, "peak_img_at_cap": at_cap}
    res["checks"]["src_cap_rule"] = (surf_massifs == zones and peaks_over == surf_massifs
                                     and bases_under == surf_massifs and at_cap == surf_massifs)

    if pre_tag:
        pre = load_grid(os.path.join(out_dir, f"stretch-{pre_tag}-surface-pre.raw"))
        post = load_grid(os.path.join(out_dir, f"stretch-{pre_tag}-surface-post.raw"))
        pre_min = interior_min(pre, 1)
        post_min = interior_min(post, 1)
        zeros = int((post == 0).sum())
        expect = (pre_min * zmul) // zdiv + zadd
        res["final"] = {
            "pre_tag": pre_tag, "pre_interior_min": pre_min, "post_interior_min": post_min,
            "expected_post_interior_min": int(expect), "cells_pinned_to_zero": zeros,
            "resample_undershoot_wu": pre_min - src_int_min,
            "floor_headroom_wu": post_min - floor_wu,
            "final_min_metres": round(post_min / 1000.0, 3),
        }
        res["checks"]["in_range"] = (zeros == 0 and post_min == expect)
        res["checks"]["floor_landing"] = (post_min >= floor_wu) if zadd < 0 else (post_min < floor_wu)

    res["failed"] = [k for k, v in res["checks"].items() if not v]
    res["case_ok"] = not res["failed"]
    res["scored"] = case.get("scored", "true") != "false"
    if not res["scored"]:
        res["note"] = ("diagnostic only - the twin-identity pre-check rejects this pair, so its "
                       "source grid is not this expanded run's own source")
    return res


def sweep_stamps(out_dir):
    """Never-lift across every run ever dumped here - generality, not one coordinate."""
    rows, violations, unstamped = [], [], []
    for path in sorted(glob.glob(os.path.join(out_dir, "height-*-zones.txt"))):
        tag = os.path.basename(path)[len("height-"):-len("-zones.txt")]
        maps, _ = parse_stamp(path)
        for env, d in maps.items():
            if not re.fullmatch(r"-?\d+", d.get("zadd", "")):
                unstamped.append({"tag": tag, "env": env, "zadd": d.get("zadd")})
                continue
            zadd = int(d["zadd"])
            rows.append({"tag": tag, "env": env, "zadd": zadd,
                         "zones": int(d.get("zones", 0)),
                         "uniform": d.get("uniform")})
            if zadd > 0:
                violations.append({"tag": tag, "env": env, "zadd": zadd})
    surf = [r for r in rows if r["env"] == "surface"]
    return {
        "stamp_files": len(set(r["tag"] for r in rows)),
        "rows": len(rows),
        "surface_rows": len(surf),
        "surface_zadd_min": min((r["zadd"] for r in surf), default=None),
        "surface_zadd_max": max((r["zadd"] for r in surf), default=None),
        "surface_clamped_to_zero": sum(1 for r in surf if r["zadd"] == 0),
        "surface_shifted_down": sum(1 for r in surf if r["zadd"] < 0),
        "underground_rows": sum(1 for r in rows if r["env"] == "underground"),
        "rows_without_a_numeric_zadd": unstamped,
        "never_lift_violations": violations,
        "detail": rows,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", action="append", required=True,
                    help="label=<name>,vanilla=<tag>,expanded=<tag>[,pre=<tag>][,scored=false]")
    ap.add_argument("--floor", type=int, default=None,
                    help="floor constant in world units (default: the payload's own Z_FLOOR_WU)")
    ap.add_argument("--perturb-src-min", type=int, default=0,
                    help="control: raise the source interior minimum by N before predicting")
    ap.add_argument("--out-dir", default=OUT)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    pf = payload_floor()
    floor_wu = args.floor if args.floor is not None else (pf if pf is not None else CONTRACT_FLOOR)

    cases = []
    for spec in args.case:
        d = dict(kv.split("=", 1) for kv in spec.split(",") if "=" in kv)
        if not {"label", "vanilla", "expanded"} <= set(d):
            raise SystemExit(f"--case {spec}: need label=, vanilla=, expanded=")
        cases.append(d)

    report = {
        "tool": "shiftcheck.py",
        "clause": "contract step 1 - interior floor shift, FLOOR and the down-only clamp",
        "floor_wu": floor_wu,
        "payload_floor_wu": pf,
        "contract_floor_wu": CONTRACT_FLOOR,
        "floor_constant_ok": (pf == CONTRACT_FLOOR),
        "perturb_src_min": args.perturb_src_min,
        "cases": [score_case(c, floor_wu, args.perturb_src_min, args.out_dir) for c in cases],
    }
    report["sweep"] = sweep_stamps(args.out_dir)
    report["never_lift_all_runs"] = not report["sweep"]["never_lift_violations"]
    report["failed_cases"] = [c["label"] for c in report["cases"]
                              if c["scored"] and not c["case_ok"]]
    report["diagnostic_cases"] = [c["label"] for c in report["cases"] if not c["scored"]]
    report["gate_ok"] = (not report["failed_cases"] and report["never_lift_all_runs"]
                         and report["floor_constant_ok"])

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    print(f"floor {floor_wu} wu (payload Z_FLOOR_WU {pf}, contract {CONTRACT_FLOOR})"
          + (f"  PERTURBED +{args.perturb_src_min}" if args.perturb_src_min else ""))
    for c in report["cases"]:
        f = c.get("final", {})
        print(f"  {c['label']:<12} {c['vanilla']}->{c['expanded']}  src_int_min "
              f"{c['source']['interior_min']:>6}  scaled {c['scaled_interior_min']:>6}  "
              f"zadd {c['zadd']:>5}  predicted {c['predicted_shift']:>5}  "
              f"[{c['branch']}] zones {c['zones']:>2} src_cap {c['src_cap']}"
              + (f"  final_min {f['post_interior_min']} ({f['final_min_metres']} m), "
                 f"pinned0 {f['cells_pinned_to_zero']}" if f else "")
              + ("  OK" if c["case_ok"] else f"  FAILED {c['failed']}")
              + ("" if c["scored"] else "  [DIAGNOSTIC, not scored]"))
    s = report["sweep"]
    print(f"  sweep: {s['surface_rows']} surface stamps over {s['stamp_files']} runs, "
          f"zadd in [{s['surface_zadd_min']}, {s['surface_zadd_max']}], "
          f"{s['surface_clamped_to_zero']} clamped / {s['surface_shifted_down']} shifted, "
          f"never-lift violations {len(s['never_lift_violations'])}")
    print(f"  gate_ok {report['gate_ok']}  failed {report['failed_cases']}")
    return 0 if report["gate_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
